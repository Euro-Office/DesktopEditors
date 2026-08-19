# Authenticated Editor Gateway + CLI — Implementation Plan

## 0. Scope & non-negotiables (from requirements)

- Gateway is **authenticated** (token) and **allowlisted** (command names + JSON-schema params, no raw string interpolation into JS — every param goes into a `scope` object that's JSON-serialized and injected as a bound variable, never string-concatenated into the script text).
- Internally backed by CDP (`Runtime.evaluate`), driven **in-process** — no CDP port, external or ephemeral, ever exists. This is a revision of the design below the line, made after a second round of code inspection; the original "embedded/helper mode with an ephemeral `127.0.0.1` CDP port" design is kept struck through for the record, not silently erased:
  - ~~gateway logic opens CDP on `127.0.0.1:0` itself; `GatewayCommandRunner` talks to it over a WebSocket (`QtWebSockets`)~~ — superseded. Investigation of the vendored CEF headers (`desktop-sdk/ChromiumBasedEditors/lib/src/cef/linux/include/cef_browser.h:563,579,590-591`, unconditionally available, no version guard) found `CefBrowserHost::SendDevToolsMessage`/`ExecuteDevToolsMethod`/`AddDevToolsMessageObserver` — CDP protocol messages sent **directly against an already-owned `CefBrowser`**, explicitly documented as not requiring any external DevTools/remote-debugging session. Since the app already tracks every open document's `CefBrowser` via `CAscApplicationManager::GetViewById`/`m_mapViews`, there is nothing left to correlate — we already hold the exact browser a command should run against. `desktop-sdk`'s `CCefView` gained a narrow, CEF-type-free bridge method, `SendGatewayDevToolsMessage(jsonMessage, messageId, callback)` (`cefview.h`/`cefview.cpp`), and `GatewayCommandRunner` calls it directly. `QtWebSockets` was added then removed from the build once this was found — no external CDP port, WebSocket dependency, or "which deployment mode" question survives this: **there is exactly one mode.**
  - Target discovery: `CAscApplicationManager::GetViewById(targetViewId)` — the app's existing view map — not CDP target URL/title matching. This part of the original design goal is unchanged, just now trivially satisfied (no correlation step needed at all, see above) rather than requiring one.
  - **Confirmed by code inspection** (`desktop-sdk/ChromiumBasedEditors/lib/src/cefwrapper/client_app.h`, `client_renderer_wrapper.cpp:593`): the app embeds real CEF/Chromium, and `apiBuilder.js` genuinely executes in Chromium's own V8 (`CAscEditorNativeV8Handler : public CefV8Handler`) — confirms `Runtime.evaluate` is literally implementable as designed, no engine-swap risk. (The F1 "Show DevTools"/`GetDebugInfoSupport()` toggle and its `--remote-debugging-port=8080` switch, `client_app.h:305-306`, remain untouched, unrelated user-facing dev feature — the gateway never touches or depends on it, in either the old or new design.)
- External transport is also config-selectable, not a single hardcoded choice:
  - **`--transport=unix-socket`** (default): a real `AF_UNIX` `SOCK_STREAM` socket, not the app's existing single-instance mechanism. Code inspection (`desktop-apps/win-linux/src/platform_linux/singleapplication.cpp:112-136`, `desktop-apps/win-linux/extras/update-daemon/src/classes/csocket.{h,cpp}`) found that `SingleApplication`'s IPC is actually a hand-rolled `CSocket` — raw `AF_INET`/`SOCK_DGRAM` UDP over loopback, bound to a per-UID-derived address (`inetAddrFromUserId()`, `csocket.cpp:62-72`, `127.<uid_hi>.<uid_lo>.1`) on a fixed/configurable port (`Utils::getInstAppPort()`, default `13012`), framed as fixed 1024-byte blobs or pipe-delimited `"cmd|param1|param2"` strings, with **zero authentication** ("primary instance" is just whoever `bind()`s first). That's the wrong shape for arbitrary JSON + real auth, and UDP has no connection state to authenticate against. So the gateway's Unix-socket transport is a genuinely new listener that reuses only the *pattern* — a per-UID-derived path so two users on the same box never collide — at e.g. `$XDG_RUNTIME_DIR/eo-gateway-<uid>.sock`, mode `0600`, giving us real OS-enforced peer isolation via `SO_PEERCRED` that UDP loopback can't provide. Auth token still required in the first frame of every connection, layered on top of (not instead of) the `SO_PEERCRED` check.
  - **`--transport=tcp-loopback`**: `127.0.0.1` only (never `0.0.0.0`), token required identically. For hosts/CLIs that can't do Unix sockets (e.g. cross-container access to a headless editor). Follows the same per-UID-derived-port idea from `csocket.cpp` so two users' gateways never collide, but rides over TCP (not UDP) so there's a real connection to authenticate before any command is accepted. Never used as a substitute for the socket's own auth — same allowlist/token logic runs underneath.
  - Both transports terminate at the same internal `GatewayServer` class; the only difference is the listen/accept layer, so allowlist and auth code is written once.
  - **Auth token mechanism** (no precedent exists anywhere in this codebase — confirmed by search: no restrictive-mode secret file, no `--token`/env-var secret pattern in `desktop-apps`/`desktop-sdk`, and the per-UID address trick above is not a real credential — so this is built from scratch): on gateway startup, generate a random token and write it to `$XDG_RUNTIME_DIR/eo-gateway-<uid>.token` with `QFile::setPermissions`/`fchmod` set to `0600` (the `fchmod` primitive is already linked into the codebase via the updater's file-copy code, `update-daemon/src/platform_linux/utils.cpp:70`, just not previously used for a secret). `eo-ctl` reads that same path when attaching.
- CLI is a **thin client + process lifecycle manager**: it can attach to an already-running editor's gateway socket, and if none is running for the target document, it launches `DesktopEditors <file>` itself (waiting for the gateway socket to come up) before connecting.
- Build order: **Word → Cell → Slide → PDF**, and within each editor, one command family at a time — implement, write its automated test, run it, only then move to the next command. After an editor's full command set lands, deploy (per the repo's existing server-build workflow) and manually/automatedly test that editor, **plus regression-test every previously completed editor's command set** before starting the next editor. No parallel agents/work — everything sequential.

## 1. Architecture

```
┌─────────────────────────────── DesktopEditors process ────────────────────────────────┐
│                                                                                         │
│  CAscApplicationManager::GetViewById(targetViewId) ───────┐                            │
│  (existing view map, m_mapViews)                          ▼                            │
│  ┌──────────────────────────┐  SendGatewayDevToolsMessage  ┌───────────────────────┐   │
│  │  CCefView (resolved)      │◄─────────────────────────────│  GatewayCommandRunner │   │
│  │  → CefBrowserHost::       │  Runtime.evaluate JSON,       │  - allowlist check    │   │
│  │    SendDevToolsMessage    │  in-process, no port/socket   │  - schema validate    │   │
│  │    (in-process CDP)       │──────────────────────────────▶│  - resolve target     │   │
│  └──────────────────────────┘  response via                 └───────────┬───────────┘   │
│                                 AddDevToolsMessageObserver                │               │
│                                                              ┌────────────▼────────────┐  │
│                                                              │      GatewayServer       │  │
│                                                              │  - token auth per conn   │  │
│                                                              │  - JSON-in/JSON-out      │  │
│                                                              │  - AF_UNIX SOCK_STREAM   │  │
│                                                              └────────────┬────────────┘  │
└───────────────────────────────────────────────────────────────────────────┼──────────────┘
                                                                             │ (auth token + JSON command)
                                                                   ┌─────────▼─────────┐
                                                                   │   CLI (eo-ctl)     │
                                                                   │  - finds/launches  │
                                                                   │    editor process  │
                                                                   │  - sends commands  │
                                                                   └────────────────────┘
```

No `--gateway-mode`/`--transport` choice survives the in-process-CDP revision above — `GatewayServer` is the only externally-reachable thing, over one transport (`AF_UNIX SOCK_STREAM`); everything upstream of it never leaves the process.

## 2. Wire protocol (shared by both transports, both modes)

Framed JSON, one object per line (or length-prefixed if binary-safety is needed later — start with newline-delimited, revisit only if a param value needs embedded newlines):

```jsonc
// request
{"auth": "<token>", "id": "req-1", "command": "word.setBold", "scope": {"paraIndex": 0, "runIndex": 2, "bold": true}}
// response
{"id": "req-1", "ok": true, "result": null}
{"id": "req-1", "ok": false, "error": {"code": "NOT_ALLOWLISTED", "message": "..."}}
```

Server-side, `command` maps 1:1 to a named entry in the allowlist table; that entry owns:
- a JSON-schema for `scope` (validated before anything touches CDP),
- the `apiBuilder.js`-backed script template with `%%SCOPE%%` as the *only* substitution point, filled by `JSON.stringify(scope)` — never by interpolating individual param values into the template string.

Example allowlist entry:
```cpp
{"word.setBold", {
  .schema = R"({"type":"object","required":["paraIndex","runIndex","bold"],
                "properties":{"paraIndex":{"type":"integer","minimum":0},
                              "runIndex":{"type":"integer","minimum":0},
                              "bold":{"type":"boolean"}}})",
  .script = R"(
    (function(scope){
      var p = Api.GetDocument().GetElement(scope.paraIndex);
      var r = p.GetElement(scope.runIndex);
      r.SetBold(scope.bold);
      return null;
    })(%%SCOPE%%);
  )"
}}
```

## 3. Repo touch points

- `desktop-sdk/ChromiumBasedEditors/lib/include/cefview.h` / `.../lib/src/cefview.cpp` — `CCefView::SendGatewayDevToolsMessage`, the in-process CDP bridge (§0/§1), built on `CefBrowserHost::SendDevToolsMessage`/`AddDevToolsMessageObserver`. **Done** — landed on `feature/cdp-gateway-cli`.
- `desktop-apps/win-linux/src/gateway/` — `GatewayServer`, `GatewayCommandRunner`, `AllowlistTable`, per-editor command-table headers (`commands/wordcommands.{h,cpp}` done; `commands/cellcommands.{h,cpp}`/`slidecommands.{h,cpp}`/`pdfcommands.{h,cpp}` to follow the build order). **Started** — infrastructure + Word §B1 landed.
- `desktop-apps/win-linux/src/main.cpp` — starts `Gateway::GatewayServer` once, after `AscAppManager::startApp()`. **Done**.
- `desktop-apps/win-linux/src/platform_linux/singleapplication.cpp` / `desktop-apps/win-linux/extras/update-daemon/src/classes/csocket.{h,cpp}` — read for the per-UID address-derivation pattern only; **not** extended directly (see §0 for why: UDP, fixed 1024-byte frames, zero auth — wrong shape for this).
- CLI: `desktop-apps/win-linux/tools/eo-ctl/` (sibling to `extras/update-daemon`), following the `x2t` precedent (`core/X2tConverter/`: own `src/main.cpp` + `build/cmake/CMakeLists.txt`, `add_executable`, wired into the parent via a single `add_subdirectory(...)` line — see `core/CMakeLists.txt:22-28`) rather than being appended into `desktop-apps`' main `COMMON_SOURCES` the way `update-daemon` currently is. **Done** (skeleton).

## 4. Command families, in build order

### Word (first)
1. Document properties (get/set title, author, keywords, custom props)
2. Content enumeration (paragraphs, tables, drawings, charts)
3. Insert/edit text (AddText, GetText)
4. Character formatting (bold, italic, font, color)
5. Paragraph formatting (align, spacing, indent)
6. Search & replace
7. Table creation/editing (rows/cols, merge, style)
8. Style creation/application
9. Insert images/shapes with positioning
10. Headers/footers, page setup
11. Bookmarks and hyperlinks
12. Form fields/content controls
13. Comments and track changes

### Cell (second)
1. Sheet management
2. Cell/range read & write
3. Number formats, merge, clear
4. Copy/paste, find/replace
5. Font/fill/border/alignment formatting
6. Conditional formatting
7. Data validation and named ranges
8. AutoFilter
9. PivotTable
10. Freeze panes
11. Insert images/shapes/OLE objects
12. Comments with replies
13. Insert/delete rows and columns
14. Recalculate formulas
15. Charts and data series
16. SmartArt read

### Slide (third)
1. Slide management (add/remove/duplicate/reorder)
2. Enumerate slide content
3. Layouts, masters, themes
4. Background, transitions
5. Shapes/text boxes with positioning
6. Text formatting (reuse Word's formatting command handlers where the underlying API is shared — same allowlist entries, different target-resolution path)
7. Insert images
8. Table creation/editing
9. Speaker notes
10. Comments
11. Document properties

### PDF (fourth)
1. Form field read/write (text/checkbox/combobox/radio)
2. Annotations (highlight, underline, strikeout, free text, ink, stamp, shapes)
3. Text search/extraction
4. Redaction
5. Page operations (add/remove)

## 5. Per-command loop (repeated for every single command in every family above — strictly sequential, no parallel agents)

Test cases for every command are pre-designed in [gateway-test-case-designs.md](gateway-test-case-designs.md) (§A cross-cutting dispatch tests, §B Word, §C Cell, §D Slide, §E PDF, §F regression instructions) — step 3 below implements *those specific cases*, not ad hoc tests invented at implementation time. If a case in that document turns out to be unimplementable as designed (e.g. a `Positive or Negative (decide)` row), the decision made resolves back into that document before the command is considered done.

1. **Plan the command**: confirm its `apiBuilder.js` backing method(s), define its scope schema. Locate the command's row(s) in gateway-test-case-designs.md.
2. **Implement**: add the allowlist entry + script template, on branch `feature/cdp-gateway-cli`.
3. **Write automated test**: implement the test case(s) from gateway-test-case-designs.md for this command, calling `GatewayCommandRunner::Execute()` directly per that document's §"Scope of this document" (bypass CLI/wire framing for functional cases; only the two shell-boundary smoke tests in §A8/A9 go through the real socket+auth, and only once total, not per command).
4. **Run it** → verify: test passes locally against a running editor instance.
5. **Commit**, signed off, no AI mention: `git commit -s` in whichever repo(s) changed (desktop-apps and/or desktop-sdk, plus the superproject if docs changed), one command's worth of change per commit.
6. Only then move to the next command in the family.

## 6. Per-editor gate (after the last command in a family)

1. **Merge `feature/cdp-gateway-cli` into `release/wayland-db-support`** (`wayland-db-support` in `core`, no `release/` prefix — confirmed per-repo naming below) in every repo touched so far (superproject, desktop-apps, desktop-sdk) — this is the branch the build/test workflow actually builds from, per user instruction. `feature/cdp-gateway-cli` is the implementation branch; `release/wayland-db-support` is the build-and-test branch.
2. Build via the existing documented workflow, run from `release/wayland-db-support`:
   ```bash
   ssh pplupo@server "cd ~/repos/DesktopEditors/desktop-sdk && git fetch fork && \
     git reset --hard fork/release/wayland-db-support && \
     cd ~/repos/DesktopEditors/build/linux && BUILDX_BAKE_ENTITLEMENTS_FS=0 ./build.sh"
   ```
3. Pull the tarball back, extract, run `DesktopEditors` locally (per CLAUDE.md's documented steps).
4. Run the full automated test suite for the editor just completed (all cases in gateway-test-case-designs.md for that editor's §) → verify: all commands pass against the freshly built binary, not just against a dev build.
5. **Regression-test every previously completed editor's command set** (the earlier editor §§ in gateway-test-case-designs.md, per its §F instructions) against this same build → verify: no cross-editor regression before starting the next editor's command family.
6. Only after a clean pass do we move to the next editor (Cell, then Slide, then PDF), continuing implementation back on `feature/cdp-gateway-cli`.

**Branch naming per repo** (as it actually exists in this checkout — confirmed by inspection, not assumed):
- superproject, `desktop-apps`, `desktop-sdk`: implementation branch `feature/cdp-gateway-cli`, merge target `release/wayland-db-support`.
- `core`: merge target is `wayland-db-support` (no `release/` prefix) — only relevant if a future command requires a `core` change; nothing in this plan currently touches `core`.
- `sdkjs`, `web-apps`: not touched by this plan (all backing methods already exist in `apiBuilder.js`); left on whatever branch they're already on (`sdkjs` is mid other work on `release/wayland-db-support` with uncommitted new commits — do not disturb it).
- Per CLAUDE.md's Euro-Office hard rules: commits are `git commit -s` (sign-off, no AI co-author mention), and pushing is forbidden by default except on `wayland-db-support`/`release/wayland-db-support` branches, or when explicitly told to push this session.

## 7. CLI (`eo-ctl`)

- `eo-ctl connect <file>` — if a gateway is already listening for `<file>`, attach; otherwise launch `DesktopEditors <file>` and poll for the socket (bounded timeout, clear error on failure) before attaching.
- `eo-ctl call <command> --scope '<json>'` — sends one command, prints the JSON response.
- `eo-ctl allowlist` — asks the gateway to list its own allowlisted commands + schemas (read-only introspection endpoint, itself allowlisted).
- Auth token: read from `$XDG_RUNTIME_DIR/eo-gateway-<uid>.token` (mode `0600`, written by the gateway on startup — see §0), never printed to stdout/logs.
- CLI grows its own command surface in lockstep with the gateway's — when a new gateway command lands in §5 step 2, the CLI gets a matching subcommand (or a generic `call` covers it and no CLI change is needed — decide per-command whether a dedicated subcommand is worth it, generic `call` is the default).
