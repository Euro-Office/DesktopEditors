// SPDX-FileCopyrightText: 2026 Euro-Office contributors
// SPDX-License-Identifier: AGPL-3.0-only

// Smoke tests for the installed desktop editors: start, start page, create,
// open, edit, save and quit, each in a fresh app instance under Xvfb.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, afterEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { App, Editor, stopDisplay, waitFor } from './lib/app.js';

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'smoke.docx');
const FIXTURE_TEXT = 'Euro-Office smoke test fixture';

let app;
afterEach(async () => {
    await app?.close();
    app = undefined;
});
after(stopDisplay);

// The start page covers itself with a loading mask until the native side
// reports app:ready; clicks before that hit the mask
async function startPage() {
    const start = await app.page('/index.html');
    await waitFor(() => start.evaluate(`!!window.$ && $('#loading-mask').length > 0 && !$('#loading-mask').is(':visible')`),
                  { what: 'the start page to finish loading (app:ready)' });
    return start;
}

// A copy of the fixture in its own directory, so lock files can be checked
function fixtureCopy() {
    const dir = mkdtempSync(join(tmpdir(), 'smoke-'));
    const file = join(dir, 'smoke.docx');
    copyFileSync(FIXTURE, file);
    return { dir, file, lock: join(dir, '.~lock.smoke.docx#') };
}

function documentXml(file) {
    return execFileSync('unzip', ['-p', file, 'word/document.xml']).toString();
}

test('starts and shows the start page', { timeout: 120000 }, async () => {
    app = await App.start('start-page');
    const start = await startPage();

    const tiles = await start.evaluate(`[...document.querySelectorAll('.document-creation-item')].map(e => e.dataset.id)`);
    assert.deepEqual(tiles, ['word', 'cell', 'slide', 'form']);

    const actions = await start.evaluate(`[...new Set([...document.querySelectorAll('.menu-item [action]')].map(e => e.getAttribute('action')))]`);
    for (const action of ['open', 'templates', 'settings', 'about'])
        assert.ok(actions.includes(action), `menu has "${action}" (has ${actions.join(', ')})`);
});

test('creates a document from the start page and edits it', { timeout: 120000 }, async () => {
    app = await App.start('new-document');
    const start = await startPage();

    await start.click('.document-creation-item[data-id=word]');
    const editor = new Editor(await app.page('/apps/api/documents/'));
    await editor.waitLoaded();

    await editor.focusEnd();
    await editor.page.type('Typed by the smoke test');
    await waitFor(async () => (await editor.text()).includes('Typed by the smoke test'),
                  { what: 'the typed text in the document' });
});

test('opens a docx, edits and saves it', { timeout: 180000 }, async () => {
    const { file, lock } = fixtureCopy();
    app = await App.start('open-edit-save', [file]);
    const editor = new Editor(await app.page('/apps/api/documents/'));
    await editor.waitLoaded();

    assert.match(await editor.title(), /smoke\.docx/);
    assert.equal((await editor.text()).trim(), FIXTURE_TEXT);
    assert.ok(existsSync(lock), 'a lock file exists while the document is open');

    await editor.focusEnd();
    await editor.page.type(' - saved');
    await waitFor(() => editor.isModified(), { what: 'the document to be modified' });
    await editor.save();

    // saving converts the document back to docx in the background
    await waitFor(() => documentXml(file).includes(`${FIXTURE_TEXT} - saved`),
                  { timeout: 30000, what: 'the saved text in the docx on disk' });
    assert.ok(!(await editor.isModified()), 'the document is no longer modified');
});

test('quits cleanly on SIGTERM', { timeout: 120000 }, async () => {
    const { file, lock } = fixtureCopy();
    app = await App.start('sigterm', [file]);
    const editor = new Editor(await app.page('/apps/api/documents/'));
    await editor.waitLoaded();
    assert.ok(existsSync(lock), 'a lock file exists while the document is open');

    const { code, signal } = await app.stop('SIGTERM');
    assert.deepEqual({ code, signal }, { code: 0, signal: null }, 'exits with code 0');
    assert.ok(!existsSync(lock), 'the lock file is removed');
    assert.equal(documentXml(file), documentXml(FIXTURE), 'the unchanged document is left as it was');
});
