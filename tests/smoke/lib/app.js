// SPDX-FileCopyrightText: 2026 Euro-Office contributors
// SPDX-License-Identifier: AGPL-3.0-only

// Starts the installed desktop editors under Xvfb and talks to their web
// pages over the Chrome DevTools Protocol. CEF reports its pages only in
// /json/list, not through Target discovery, so Playwright and Puppeteer can't
// attach; chrome-remote-interface connects to each page's websocket directly.

import { execFileSync, execSync, spawn } from 'node:child_process';
import { lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import CDP from 'chrome-remote-interface';

const CDP_OPTIONS = { host: '127.0.0.1', port: 9222 };
export const RESULTS_DIR = process.env.RESULTS_DIR || join(process.cwd(), 'results');
const DISPLAY = ':99';

export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function waitFor(check, { timeout = 30000, interval = 250, what = 'condition' } = {}) {
    const end = Date.now() + timeout;
    let lastError;
    while (Date.now() < end) {
        try {
            const value = await check();
            if (value) return value;
        } catch (e) {
            lastError = e;
        }
        await sleep(interval);
    }
    throw new Error(`Timed out after ${timeout} ms waiting for ${what}${lastError ? `: ${lastError.message}` : ''}`);
}

// The launcher the package installs in /usr/bin, which sets up the library
// path and starts DesktopEditors, as for users. APP_LAUNCHER overrides it.
// The install directory depends on the brand (/opt/<company>/<product>).
function launcher() {
    if (process.env.APP_LAUNCHER) return process.env.APP_LAUNCHER;
    const binary = execSync('ls /opt/*/*/DesktopEditors').toString().trim().split('\n')[0];
    const pkg = execFileSync('dpkg', ['-S', binary]).toString().split(':')[0];
    // the package also links "desktopeditors" to the launcher
    const bins = execFileSync('dpkg', ['-L', pkg]).toString().split('\n')
        .filter(f => f.startsWith('/usr/bin/') && lstatSync(f).isFile());
    if (bins.length !== 1) throw new Error(`Expected one launcher in /usr/bin for ${pkg}, found: ${bins.join(', ')}`);
    return bins[0];
}

let xvfb;
export function startDisplay() {
    if (xvfb) return;
    mkdirSync(RESULTS_DIR, { recursive: true });
    xvfb = spawn('Xvfb', [DISPLAY, '-screen', '0', '1600x1000x24', '-nolisten', 'tcp'], { stdio: 'ignore' });
    process.env.DISPLAY = DISPLAY;
}

export function stopDisplay() {
    xvfb?.kill();
    xvfb = undefined;
}

// The whole X screen, so native dialogs show up too
export function screenshot(name) {
    try {
        execSync(`xwd -root -silent -display ${DISPLAY} | convert xwd:- png:${join(RESULTS_DIR, `${name}.png`)}`);
    } catch (e) {
        console.log(`screenshot ${name} failed: ${e.message}`);
    }
}

export class App {
    static async start(name, args = []) {
        startDisplay();
        const logFile = join(RESULTS_DIR, `${name}.log`);
        const log = openSync(logFile, 'w');
        const app = new App(name);
        // A fresh home per instance, so no profile, cache or recovery state
        // carries over from one test to the next. In its own process group, so
        // CEF's helper processes can be stopped with it.
        app.home = mkdtempSync(join(tmpdir(), `home-${name}-`));
        app.process = spawn(launcher(), [`--remote-debugging-port=${CDP_OPTIONS.port}`, ...args], {
            stdio: ['ignore', log, log],
            env: { ...process.env, DISPLAY, HOME: app.home },
            detached: true,
        });
        app.exited = new Promise(resolve => app.process.on('exit', (code, signal) => resolve({ code, signal })));
        // fail right away with the app's own output if it doesn't start at all
        const died = app.exited.then(({ code, signal }) => {
            const output = readFileSync(logFile, 'utf8').trim().split('\n').slice(-10).join('\n');
            throw new Error(`The app exited during startup (code ${code}, signal ${signal}):\n${output}`);
        });
        await Promise.race([waitFor(() => CDP.Version(CDP_OPTIONS), { timeout: 60000, what: 'the DevTools endpoint' }), died]);
        died.catch(() => {});
        return app;
    }

    constructor(name) {
        this.name = name;
        this.clients = [];
    }

    async targets() {
        return (await CDP.List(CDP_OPTIONS)).filter(t => t.type === 'page');
    }

    // Waits for a page whose URL matches and connects to it
    async page(urlPart, { timeout = 60000 } = {}) {
        const target = await waitFor(async () => (await this.targets()).find(t => t.url.includes(urlPart)),
                                     { timeout, what: `a page with "${urlPart}" in its URL` });
        return this.connect(target);
    }

    // All editor tabs; each is the editor API wrapper with the editor in an iframe
    async editors() {
        const editors = [];
        for (const target of (await this.targets()).filter(t => t.url.includes('/apps/api/documents/')))
            editors.push(await this.connect(target));
        return editors;
    }

    async connect(target) {
        const client = await CDP({ ...CDP_OPTIONS, target });
        this.clients.push(client);
        return new Page(client);
    }

    // Sends a signal and waits for the process to exit
    async stop(signal = 'SIGTERM', timeout = 30000) {
        await this.disconnect();
        if (this.process.exitCode !== null || this.process.signalCode !== null)
            return { code: this.process.exitCode, signal: this.process.signalCode };
        this.process.kill(signal);
        return Promise.race([
            this.exited,
            sleep(timeout).then(() => { throw new Error(`${this.name} did not exit within ${timeout} ms after ${signal}`); }),
        ]);
    }

    // Cleanup after a test: screenshot, then make sure nothing is left running.
    // Helper processes left over from one test would keep the CEF profile
    // locked and break the next app instance.
    async close() {
        screenshot(this.name);
        await this.disconnect();
        if (this.process.exitCode === null && this.process.signalCode === null)
            this.process.kill('SIGKILL');
        await this.exited;
        try {
            process.kill(-this.process.pid, 'SIGKILL');
        } catch {
            // the group is already gone
        }
        await waitFor(() => { try { process.kill(-this.process.pid, 0); return false; } catch { return true; } },
                      { timeout: 10000, what: 'the helper processes to exit' });
        // the app is single-instance; give the next start a clean slate
        await waitFor(async () => { try { await CDP.Version(CDP_OPTIONS); return false; } catch { return true; } },
                      { timeout: 10000, what: 'the DevTools endpoint to close' }).catch(() => {});
    }

    async disconnect() {
        await Promise.all(this.clients.splice(0).map(c => c.close().catch(() => {})));
    }
}

export class Page {
    constructor(client) {
        this.client = client;
    }

    async evaluate(expression) {
        const result = await this.client.Runtime.evaluate({ expression, returnByValue: true, awaitPromise: true });
        if (result.exceptionDetails)
            throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
        return result.result.value;
    }

    // Clicks the centre of the first element matching selector with real mouse events
    async click(selector) {
        const point = await this.evaluate(`(() => {
            const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
            return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
        })()`);
        await this.clickAt(point.x, point.y);
    }

    async clickAt(x, y) {
        for (const type of ['mousePressed', 'mouseReleased'])
            await this.client.Input.dispatchMouseEvent({ type, x, y, button: 'left', clickCount: 1 });
    }

    async key(key, code, keyCode, modifiers = 0) {
        for (const type of ['keyDown', 'keyUp'])
            await this.client.Input.dispatchKeyEvent({ type, key, code, windowsVirtualKeyCode: keyCode, modifiers });
    }

    async type(text) {
        await this.client.Input.insertText({ text });
    }
}

// The document editor inside an editor tab's iframe
export class Editor {
    static EDITOR = `document.querySelector('iframe').contentWindow.editor`;

    constructor(page) {
        this.page = page;
    }

    async waitLoaded(timeout = 60000) {
        await waitFor(() => this.page.evaluate(`!!(${Editor.EDITOR} && ${Editor.EDITOR}.isDocumentLoadComplete)`),
                      { timeout, what: 'the document to load' });
    }

    title() {
        return this.page.evaluate(`document.querySelector('iframe').contentWindow.document.title`);
    }

    async text() {
        await this.page.evaluate(`${Editor.EDITOR}.asc_EditSelectAll()`);
        return this.page.evaluate(`${Editor.EDITOR}.asc_GetSelectedText()`);
    }

    isModified() {
        return this.page.evaluate(`${Editor.EDITOR}.isDocumentModified()`);
    }

    // Clicks into the first page and moves the cursor to the end of the document
    async focusEnd() {
        await this.page.clickAt(600, 320);
        await this.page.key('End', 'End', 35, 2 /* Ctrl */);
    }

    // Starts saving; the file is written asynchronously afterwards
    save() {
        return this.page.evaluate(`${Editor.EDITOR}.asc_Save()`);
    }
}
