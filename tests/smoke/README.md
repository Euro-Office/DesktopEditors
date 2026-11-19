# Smoke tests

End-to-end checks of the installed Linux app. `run.sh` installs a desktop
editors `.deb` on a minimal Ubuntu 24.04 with only the package's own
dependencies, starts the app under Xvfb and drives it over the Chrome DevTools
Protocol. Each test runs a fresh app instance with an empty profile:

- it starts and the start page finishes loading
- a document, spreadsheet and presentation can be created from the start page,
  and the document typed into
- a `.docx`, `.odt`, `.xlsx` and `.pptx` passed on the command line opens, can
  be edited and saved, and the saved file on disk contains the change in its
  own format; a `.~lock.<name>#` file exists while it's open
- the same for a path with spaces and non-ASCII characters
- launching it again with another file opens that file in the running instance
- an opened file is listed under recent files after a restart and reopens from
  there
- SIGTERM shuts it down with exit code 0 and removes the lock file

CI runs them in the `smoke-linux` job of `.github/workflows/build.yml`, on
every build including PRs, against each `.deb` that `build-linux` produced
(both brands, amd64 and arm64). Each job uploads `smoke-results-<brand>-<arch>`
with a screenshot of the whole screen and the app's output for each test.

## Running locally

Needs Docker with BuildKit.

```bash
tests/smoke/run.sh path/to/euro-office-..._amd64.deb [results-dir]
```

To test a CI build, download its `linux-packages-euro-office-amd64` artifact,
for example with `gh run download RUN_ID -n linux-packages-euro-office-amd64`.

## How it works

CEF lists its pages under `/json/list` but not through the DevTools target
discovery Playwright and Puppeteer rely on, so they can't attach.
`lib/app.js` connects to each page's websocket with `chrome-remote-interface`
instead, and sends real mouse and keyboard input through it.

- The start page is `index.html`. Wait for `#loading-mask` to disappear before
  clicking: the native side is ready only then.
- An editor tab is `apps/api/documents/index.html`; the editor itself runs in
  its iframe (`Editor` in `lib/app.js` wraps the sdkjs API there).
- Screenshots are taken from the X display, so native Qt/GTK dialogs show up
  too, unlike CDP page screenshots.
- The app runs as a regular user: started as root it opens a warning dialog
  first.
