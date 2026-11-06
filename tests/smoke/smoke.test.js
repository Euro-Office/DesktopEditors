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
import { App, Editor, sleep, stopDisplay, waitFor } from './lib/app.js';

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const FIXTURE = join(FIXTURES, 'smoke.docx');
// The text in each fixture: the docx and odt paragraph, cell A1 of the xlsx
// (B1 is 41) and the first of the two slides of the pptx
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

// A copy of a fixture in its own directory, so lock files can be checked
function fixtureCopy(fixture = 'smoke.docx', { name = fixture, dirPrefix = 'smoke-' } = {}) {
    const dir = mkdtempSync(join(tmpdir(), dirPrefix));
    const file = join(dir, name);
    copyFileSync(join(FIXTURES, fixture), file);
    return { dir, file, lock: join(dir, `.~lock.${name}#`) };
}

// The concatenated XML of the zip entries matching pattern
function zipXml(file, pattern) {
    return execFileSync('unzip', ['-p', file, pattern]).toString();
}

function zipEntries(file) {
    return execFileSync('unzip', ['-Z1', file]).toString().trim().split('\n');
}

const documentXml = file => zipXml(file, 'word/document.xml');

async function openEditor(name, file) {
    app = await App.start(name, [file]);
    const editor = new Editor(await app.page('/apps/api/documents/'));
    await editor.waitLoaded();
    return editor;
}

// Saves and waits for the file on disk to pass check; saving converts the
// document back to its format in the background
async function saveAndCheck(editor, check, what) {
    await waitFor(() => editor.isModified(), { what: 'the document to be modified' });
    await editor.save();
    await waitFor(check, { timeout: 30000, what });
    await waitFor(async () => !(await editor.isModified()), { timeout: 10000, what: 'the document to be no longer modified' });
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

// The document editor is covered by the next test, which also types into it
for (const [tile, type] of [['cell', Editor.CELL], ['slide', Editor.SLIDE]]) {
    test(`creates a ${tile} document from the start page`, { timeout: 120000 }, async () => {
        app = await App.start(`new-${tile}`);
        const start = await startPage();

        await start.click(`.document-creation-item[data-id=${tile}]`);
        const editor = new Editor(await app.page('/apps/api/documents/'));
        await editor.waitLoaded();
        assert.equal(await editor.type(), type);
    });
}

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
    const editor = await openEditor('open-edit-save', file);

    assert.match(await editor.title(), /smoke\.docx/);
    assert.equal((await editor.text()).trim(), FIXTURE_TEXT);
    assert.ok(existsSync(lock), 'a lock file exists while the document is open');

    await editor.focusEnd();
    await editor.page.type(' - saved');
    await saveAndCheck(editor, () => documentXml(file).includes(`${FIXTURE_TEXT} - saved`),
                       'the saved text in the docx on disk');
});

test('opens an odt, edits and saves it as odt', { timeout: 180000 }, async () => {
    const { file } = fixtureCopy('smoke.odt');
    const editor = await openEditor('odt', file);
    assert.equal(await editor.type(), Editor.WORD);
    assert.equal((await editor.text()).trim(), FIXTURE_TEXT);

    await editor.focusEnd();
    await editor.page.type(' - saved');
    await saveAndCheck(editor, () => zipXml(file, 'content.xml').includes(`${FIXTURE_TEXT} - saved`),
                       'the saved text in content.xml of the odt on disk');
    assert.equal(zipXml(file, 'mimetype'), 'application/vnd.oasis.opendocument.text', 'it is still an odt');
});

test('opens an xlsx, edits a cell and saves it', { timeout: 180000 }, async () => {
    const { file } = fixtureCopy('smoke.xlsx');
    const editor = await openEditor('xlsx', file);
    assert.equal(await editor.type(), Editor.CELL);
    assert.equal(await editor.cellText(), FIXTURE_TEXT, 'A1 is active and has the fixture text');

    // into A2, then type into it and commit with Enter
    await editor.page.clickAt(600, 320);
    await editor.page.key('Home', 'Home', 36, 2 /* Ctrl */);
    await editor.page.key('ArrowDown', 'ArrowDown', 40);
    await editor.page.type('Typed by the smoke test');
    await editor.page.key('Enter', 'Enter', 13);
    await editor.page.key('ArrowUp', 'ArrowUp', 38);
    await waitFor(async () => (await editor.cellText()) === 'Typed by the smoke test', { what: 'the typed text in A2' });

    await saveAndCheck(editor, () => zipXml(file, 'xl/*.xml').includes('Typed by the smoke test'),
                       'the typed text in the xlsx on disk');
    const xml = zipXml(file, 'xl/*.xml');
    assert.ok(xml.includes(FIXTURE_TEXT), 'A1 is kept');
    assert.match(zipXml(file, 'xl/worksheets/sheet1.xml'), /<c r="B1"[^>]*>(<f>[^<]*<\/f>)?<v>41<\/v>/, 'B1 is kept');
});

test('opens a pptx, adds a slide and saves it', { timeout: 180000 }, async () => {
    const { file } = fixtureCopy('smoke.pptx');
    const editor = await openEditor('pptx', file);
    assert.equal(await editor.type(), Editor.SLIDE);
    assert.equal(await editor.slideCount(), 2);

    await editor.page.clickAt(600, 320);
    await editor.page.key('Escape', 'Escape', 27);
    await editor.page.key('m', 'KeyM', 77, 2 /* Ctrl */);
    await waitFor(async () => (await editor.slideCount()) === 3, { what: 'a third slide' });

    const slides = () => zipEntries(file).filter(e => /^ppt\/slides\/slide\d+\.xml$/.test(e));
    await saveAndCheck(editor, () => slides().length === 3, 'three slides in the pptx on disk');
    assert.ok(zipXml(file, 'ppt/slides/*.xml').includes(FIXTURE_TEXT), 'the first slide is kept');
});

test('opens and saves a file with spaces and non-ASCII characters in its path', { timeout: 180000 }, async () => {
    const name = 'Prüfung – ä ß 文档.docx';
    const { file, lock } = fixtureCopy('smoke.docx', { name, dirPrefix: 'Ordner mit Leerzeichen ' });
    const editor = await openEditor('unicode-path', file);

    assert.ok((await editor.title()).includes(name), `the title shows "${name}"`);
    assert.ok(existsSync(lock), 'a lock file exists while it is open');

    await editor.focusEnd();
    await editor.page.type(' - gespeichert ✓');
    await saveAndCheck(editor, () => documentXml(file).includes(`${FIXTURE_TEXT} - gespeichert ✓`),
                       'the saved text in the docx on disk');
});

test('a second launch opens its file in the running instance', { timeout: 180000 }, async () => {
    const docx = fixtureCopy('smoke.docx');
    const xlsx = fixtureCopy('smoke.xlsx');
    await openEditor('second-launch', docx.file);

    await app.launchAgain([xlsx.file]);
    assert.equal(app.process.exitCode, null, 'the first instance is still running');

    await waitFor(async () => (await app.editors()).length === 2, { what: 'a second editor tab' });
    const types = [];
    for (const page of await app.editors()) {
        const editor = new Editor(page);
        await editor.waitLoaded();
        types.push(await editor.type());
    }
    assert.deepEqual(types.sort(), [Editor.WORD, Editor.CELL]);
});

test('lists an opened file under recent files and reopens it from there', { timeout: 180000 }, async () => {
    const { file } = fixtureCopy();
    await openEditor('recent-first', file);
    const { code } = await app.stop('SIGTERM');
    assert.equal(code, 0);
    await app.close();
    const { home } = app;

    app = await App.start('recent', [], { home });
    const start = await startPage();
    const row = `#box-recent .row.text-normal:has(.col-name[title="smoke.docx"])`;
    await waitFor(() => start.evaluate(`!!document.querySelector(${JSON.stringify(row)})`),
                  { what: 'smoke.docx in the recent files' });
    assert.ok((await start.evaluate(`document.querySelector(${JSON.stringify(`${row} .col-location`)}).title`)).includes(dirname(file)),
              'the recent entry shows its directory');

    // openFile ignores clicks within a second of the last one, counting from
    // when the start page loaded
    await sleep(1000);
    await start.click(row);
    const editor = new Editor(await app.page('/apps/api/documents/'));
    await editor.waitLoaded();
    assert.match(await editor.title(), /smoke\.docx/);
    assert.equal((await editor.text()).trim(), FIXTURE_TEXT);
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
