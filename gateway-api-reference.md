# Gateway API & CLI Reference

Generated from the actual committed source — `desktop-apps/win-linux/src/gateway/commands/{word,cell,slide,pdf}commands.cpp`, `gatewayserver.cpp`, `gatewaytypes.h`, and `tools/eo-ctl/src/main.cpp` — on `feature/cdp-gateway-cli`. Every scope field, return shape, and error case below is read directly from that code, not reconstructed from memory. See [cdp-gateway-cli-plan.md](cdp-gateway-cli-plan.md) for the architecture and [gateway-test-case-designs.md](gateway-test-case-designs.md) for the full test matrix each command was built against.

## 1. Transport & authentication

- **Socket**: `$XDG_RUNTIME_DIR/eo-gateway-<uid>.sock` (falls back to `$TMPDIR` if `XDG_RUNTIME_DIR` is unset), a real `AF_UNIX SOCK_STREAM` socket (`QLocalServer`/`QLocalSocket`), mode `0600`.
- **Token**: `$XDG_RUNTIME_DIR/eo-gateway-<uid>.token`, mode `0600`, a fresh random `QUuid` written by the gateway on every startup. Read this file's contents verbatim as the `auth` value.
- **Protocol**: one JSON object per connection, newline-terminated, one-shot request/response (connect → send → read one line → disconnect). No persistent session.

**Request**
```json
{"id": "<any client-chosen string>", "command": "<command name>", "scope": { /* per-command params */ }, "auth": "<token>"}
```
`targetViewId` is also accepted at the top level (integer, which open document/window to run against) — required by the actual gateway; the schema-validation tests in this repo bypass it by calling `Execute()` directly, so it's undocumented at the per-command level below, but real wire requests need it.

**Response — success**
```json
{"id": "<echoed id>", "ok": true, "result": /* per-command return value, or null */}
```

**Response — failure**
```json
{"id": "<echoed id>", "ok": false, "error": {"code": "<ERROR_CODE>", "message": "<human-readable>"}}
```

**Error codes** (`gatewaytypes.h`):

| Code | Meaning |
|---|---|
| `NOT_ALLOWLISTED` | Unknown command name — never reaches the target document. |
| `SCHEMA_INVALID` | `scope` failed the command's own field-level validation — never reaches the target document. |
| `TARGET_NOT_FOUND` | No open document matches `targetViewId`. |
| `SCRIPT_EXCEPTION` | The command's script threw inside the document (bad index, unresolvable range/sheet/slide, rejected value, etc.) — this is the general "something about your *values* was wrong" bucket, distinct from `SCHEMA_INVALID`'s "something about your *shape/types* was wrong". |
| `UNAUTHENTICATED` | Wrong or missing `auth` token — connection-level, before any command runs. |

Two meta commands are handled directly by `GatewayServer` (not part of any editor's allowlist table):

- **`gateway.listCommands`** — takes no `scope`, returns a JSON array of every currently-registered command name.
- **`gateway.connect`** — `{"path": "<absolute or relative file path>"}` → `{"targetViewId": <integer>}`. A pure resolver: matches an already-open view for `path` via `CAscApplicationManager::GetViewByUrl` (checking the view's `GetUrl()`/`GetOriginalUrl()`/`GetUrlAsLocal()`, after normalizing `path` the same way `handleInputCmd` does before a view's local-file URL is set) and returns its id, or `{"targetViewId": -1}` if not open yet — **not** an error, since a client is expected to poll this after launching `DesktopEditors <path>` (see `eo-ctl connect` below). This command never opens anything itself; empty `path` returns `SCHEMA_INVALID`.

## 2. CLI (`eo-ctl`)

Thin client — every subcommand just frames the request above and prints the raw response. No business logic lives in the CLI (the one exception, `connect`'s poll loop, is factored out into `tools/eo-ctl/src/connectlogic.h`/`.cpp`, unit-tested independently — see `tools/eo-ctl/tests/connectlogic_test.cpp`).

```bash
# Resolve <file> to a stable view id, launching DesktopEditors (or opening a new tab
# in an already-running instance) if it isn't already open. Idempotent -- calling this
# again for a file already open returns the same id. Prints {"targetViewId": <id>} and
# exits 0 on success, or exits 1 (nothing printed to stdout) if it never resolves
# within 30s.
eo-ctl connect <file>

# Send one command, print the JSON response, exit 0 on ok:true / 1 on ok:false.
eo-ctl call <command> --scope '<json>' [--target <viewId>]

# List every currently-registered command name (calls the gateway.listCommands meta command).
eo-ctl allowlist
```

`--scope` defaults to `{}` if omitted; `--target` defaults to `-1` (which will fail with `TARGET_NOT_FOUND` unless the gateway is only tracking one document — pass the real view id returned by `connect` in practice). The auth token is read automatically from `$XDG_RUNTIME_DIR/eo-gateway-<uid>.token`; never pass it on the command line.

**Example session:**
```bash
eo-ctl connect ~/Documents/report.docx
# → {"targetViewId":1}
eo-ctl call word.setTitle --scope '{"title":"Q3 Report"}' --target 1
eo-ctl call word.getTitle --scope '{}' --target 1
eo-ctl allowlist
```

### `connect`'s resolution algorithm

`gateway.connect` never opens a file itself (see §1) — `eo-ctl connect` is what actually
does, by launching `DesktopEditors <file>` as a subprocess and relying on
`SingleApplication` (`win-linux/src/main.cpp`, `cascapplicationmanagerwrapper.cpp`) to
handle both cases identically: a cold start opens `file` directly as its initial
document; if an instance is already running, the launch forwards `file` to it via
`sendMessage`/`receivedMessage`, and the existing instance opens it as a new tab via
`handleInputCmd` — confirmed against the actual source, not assumed.

1. If the gateway socket doesn't exist yet: launch `DesktopEditors <file>`, wait
   (bounded, 30s) for the socket to appear. The freshly-launched instance opens `file`
   as its initial document.
2. Call `gateway.connect{path: file}`. If it returns a real id, done.
3. Otherwise (socket already existed, file not open yet): launch
   `DesktopEditors <file>` again — this is what triggers the forward-to-existing-
   instance-and-open-a-new-tab path — then poll `gateway.connect` (200ms interval,
   30s bounded) until it resolves or times out.

**PDF example session:**
```bash
eo-ctl connect ~/Documents/invoice.pdf
eo-ctl call pdf.getAllFields --scope '{}' --target 2
eo-ctl call pdf.setFieldValue --scope '{"key":"Total","value":"500.00"}' --target 2
eo-ctl call pdf.addHighlight --scope '{"page":0,"rect":[10,10,100,20]}' --target 2
```

---

## 3. Word commands (`word.*`)

### Document properties

#### `word.getTitle`
No scope fields. Returns the document title (`string`).
```json
{"command":"word.getTitle","scope":{}}
→ {"ok":true,"result":"Q3 Report"}
```

#### `word.setTitle`
| Field | Type | Required | Notes |
|---|---|---|---|
| `title` | string | yes | empty string allowed |

Returns `null`.
```json
{"command":"word.setTitle","scope":{"title":"Q3 Report"}}
→ {"ok":true,"result":null}
```

#### `word.setCustomProperty`
| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | non-empty |
| `value` | string \| number \| boolean | yes | |

Returns `null`. Throws `SCRIPT_EXCEPTION` if the value's type isn't supported by the underlying setter.
```json
{"command":"word.setCustomProperty","scope":{"name":"Reviewed","value":"true"}}
→ {"ok":true,"result":null}
```

#### `word.getCustomProperty`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns the property's value, or `null` if the name doesn't exist (not an error).

### Content enumeration

#### `word.getAllParagraphs` / `word.getAllTables` / `word.getAllDrawingObjects` / `word.getAllCharts`
No scope fields. Each returns an array of **0-based indices** (`[0,1,2,...]`), not object handles — these indices are what `paraIndex`/`tableIndex`/`drawingIndex` elsewhere in this reference expect.
```json
{"command":"word.getAllParagraphs","scope":{}}
→ {"ok":true,"result":[0,1,2]}
```

### Insert/edit text

#### `word.addText`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `text` | string | yes (empty allowed) |

Returns `null`. **Always appends a new run** — does not edit an existing run in place.

#### `word.getText`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `runIndex` | integer ≥0 | yes |

Returns the run's text (`string`).

### Character formatting

#### `word.setBold`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `runIndex` | integer ≥0 | yes |
| `bold` | boolean | yes |

Returns `null`.

#### `word.setItalic`
Same shape as `setBold` with `italic: boolean` in place of `bold`.

#### `word.setFontFamily`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `runIndex` | integer ≥0 | yes |
| `font` | string | yes, non-empty (any name accepted — font substitution is a rendering concern, not validated here) |

Returns `null`.

#### `word.setColor`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `runIndex` | integer ≥0 | yes | |
| `color` | string | yes | must match `^#[0-9A-Fa-f]{6}$` |

Returns `null`.
```json
{"command":"word.setColor","scope":{"paraIndex":0,"runIndex":0,"color":"#FF0000"}}
→ {"ok":true,"result":null}
```

### Paragraph formatting

#### `word.setJc`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `align` | string | yes | one of `left`, `right`, `center`, `both` |

Returns `null`.

#### `word.setSpacingBefore`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `twips` | integer | yes | 1/1440 inch — **not points** |

Returns `null`.

#### `word.setIndLeft`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `twips` | integer | yes | negative allowed (hanging indent), no minimum |

Returns `null`.

### Search & replace

#### `word.search`
| Field | Type | Required |
|---|---|---|
| `text` | string | yes, non-empty |

Returns the **match count** (`integer`), not match locations.

#### `word.searchAndReplace`
| Field | Type | Required |
|---|---|---|
| `find` | string | yes, non-empty |
| `replace` | string | yes (empty allowed) |

Returns the underlying `SearchAndReplace` boolean result.

### Table creation and editing

`tableIndex` addresses into `word.getAllTables`'s index space throughout this section.

#### `word.addRow`
| Field | Type | Required | Notes |
|---|---|---|---|
| `tableIndex` | integer ≥0 | yes | |
| `rowIndex` | integer ≥0 | yes | new row inserted **after** this row |

Returns `null`.

#### `word.addColumn`
| Field | Type | Required | Notes |
|---|---|---|---|
| `tableIndex` | integer ≥0 | yes | |
| `colIndex` | integer ≥0 | yes | new column inserted **after** this column |

Returns `null`.

#### `word.mergeCells`
| Field | Type | Required |
|---|---|---|
| `tableIndex` | integer ≥0 | yes |
| `fromRow`, `fromCol`, `toRow`, `toCol` | integer ≥0 | yes |

Returns `null`. Throws `SCRIPT_EXCEPTION` if the merge fails (e.g. degenerate/overlapping range).

#### `word.setStyle`
| Field | Type | Required |
|---|---|---|
| `tableIndex` | integer ≥0 | yes |
| `styleId` | string | yes, non-empty |

Returns `null`. Throws if `styleId` doesn't resolve to an existing style.

### Style creation and application

#### `word.createStyle`
| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | |
| `type` | string | yes | one of `paragraph`, `table`, `run`, `numbering` |

Returns `null`. Idempotent — re-creating an existing name replaces it (confirmed in source, not just assumed).

#### `word.getStyle`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns `boolean` — whether a style with that name exists (not a handle).

#### `word.setStyleTextPr`
| Field | Type | Required |
|---|---|---|
| `styleId` | string | yes, non-empty |
| `bold` | boolean | yes |

Returns `null`. Throws if `styleId` doesn't exist.

### Insert images/shapes with positioning

#### `word.createImage`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `imageSrc` | string | yes | **URL or base64 data URI only — not a local file path** |
| `width`, `height` | integer ≥1 | yes | EMU (914400 EMU = 1 inch) |

Returns `null`.
```json
{"command":"word.createImage","scope":{"paraIndex":0,"imageSrc":"data:image/png;base64,iVBORw0KG...","width":914400,"height":914400}}
```

#### `word.setWrappingStyle`
| Field | Type | Required | Notes |
|---|---|---|---|
| `drawingIndex` | integer ≥0 | yes | indexes `word.getAllDrawingObjects` |
| `style` | string | yes | one of `inline`, `square`, `tight`, `through`, `topAndBottom`, `behind`, `inFront` |

Returns `boolean`.

#### `word.setHorPosition`
| Field | Type | Required | Notes |
|---|---|---|---|
| `drawingIndex` | integer ≥0 | yes | |
| `distanceEmu` | integer ≥0 | yes | |
| `relativeTo` | string | yes | one of `character`, `column`, `leftMargin`, `rightMargin`, `margin`, `page` |

Returns `boolean`.

### Headers/footers, page setup

#### `word.setHeaderText`
| Field | Type | Required | Notes |
|---|---|---|---|
| `type` | string | yes | one of `title`, `even`, `default` |
| `text` | string | yes (empty allowed) | |

Returns `null`. Operates on the document's one final section — no `sectionIndex` param (multi-section documents aren't addressable through this command).

#### `word.setPageMargins`
| Field | Type | Required |
|---|---|---|
| `left`, `top`, `right`, `bottom` | integer ≥0 | yes |

Returns `boolean`. Twips.

#### `word.setPageSize`
| Field | Type | Required |
|---|---|---|
| `width`, `height` | integer ≥1 | yes |

Returns `boolean`. Twips.

### Bookmarks and hyperlinks

#### `word.addBookmark`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `name` | string | yes, non-empty |

Returns `null`.

#### `word.getBookmark`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns `boolean`.

#### `word.addHyperlink`
| Field | Type | Required | Notes |
|---|---|---|---|
| `paraIndex` | integer ≥0 | yes | |
| `text` | string | yes, non-empty | |
| `url` | string | yes | must start with `http://`, `https://`, or `mailto:` — enforced as a security boundary, `javascript:`/`file:` etc. rejected with `SCHEMA_INVALID` |

Returns `null`. Note: this both inserts `text` into the paragraph **and** wraps it as the hyperlink label in one call.

### Fillable form fields

#### `word.addTextForm`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `key` | string | yes, non-empty |

Returns `null`.

#### `word.getAllForms`
No scope fields. Returns an array of form **keys** (`string[]`).

#### `word.setFormsData`
| Field | Type | Required | Notes |
|---|---|---|---|
| `data` | object | yes | `{key: value, ...}` — any keys not matching an existing form are silently ignored |

Returns `boolean`.
```json
{"command":"word.setFormsData","scope":{"data":{"name":"Alice","agree":true}}}
```

> **Not implemented**: `word.addCheckBoxForm` — no confirmed insertion API for a created checkbox form was found; see [gateway-test-case-designs.md](gateway-test-case-designs.md) §B12.

### Comments and track changes

#### `word.addComment`
| Field | Type | Required |
|---|---|---|
| `paraIndex` | integer ≥0 | yes |
| `text` | string | yes, non-empty |
| `author` | string | no (empty allowed → defaults to current user) |

Returns `null`.

#### `word.getAllComments`
No scope fields. Returns `[{text: string, author: string}, ...]`.

#### `word.setTrackRevisions`
| Field | Type | Required |
|---|---|---|
| `enabled` | boolean | yes |

Returns `boolean`.

#### `word.acceptAllRevisionChanges`
No scope fields. Returns `null`.

---

## 4. Cell commands (`cell.*`)

### Sheet management

#### `cell.addSheet`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns `null`. Throws `SCRIPT_EXCEPTION` on a duplicate name.

#### `cell.getSheets`
No scope fields. Returns sheet **names** (`string[]`), in order.

#### `cell.setActiveSheet`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns `null`.

#### `cell.getActiveSheet`
No scope fields. Returns the active sheet's name (`string`).

#### `cell.setVisible`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |
| `visible` | boolean | yes |

Returns `null`.

#### `cell.setName`
| Field | Type | Required |
|---|---|---|
| `oldName` | string | yes, non-empty |
| `newName` | string | yes, non-empty |

Returns `null`.

### Cell/range read & write

`sheet`+`range` (e.g. `"A1"`, `"A1:C10"`) address every command in this section and the next several.

#### `cell.setValue`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet` | string | yes | |
| `range` | string | yes | |
| `value` | string \| number \| boolean | yes | a string starting with `=` becomes a formula — there is no separate formula field |

Returns `true`. Throws on a protected sheet or unresolvable range.
```json
{"command":"cell.setValue","scope":{"sheet":"Sheet1","range":"A1","value":"=1+1"}}
```

#### `cell.getValue`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `range` | string | yes |

Returns the cell's value — a scalar for a single cell, a nested array for a multi-cell range.

#### `cell.getFormula`
Same scope as `getValue`. Returns `"= " + formula text` (note the literal space) if the cell has a formula, otherwise its plain value.

### Number formats, merge, clear

#### `cell.setNumberFormat`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |
| `format` | string | yes, non-empty |

Returns `null`.

#### `cell.merge`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `across` | boolean | yes | `true` merges each row separately; `false` merges the whole range into one cell |

Returns `null`.

#### `cell.clearContents`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |

Returns `null`.

### Copy/paste, find/replace

#### `cell.copy`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `from`, `to` | string | yes |

Returns `null`.

#### `cell.find`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `text` | string | yes (empty allowed) |

Returns the **first match's address** (`string`) within the sheet's used range, or `null` — not a list of all matches.

#### `cell.replace`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `find` | string | yes, non-empty |
| `replace` | string | yes (empty allowed) |

Returns the matched range's address (`string`) or `null`. Replaces **all** occurrences (`ReplaceAll: true` internally).

### Formatting (font/fill/border/alignment)

#### `cell.setFontName`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |
| `font` | string | yes, non-empty |

Returns `null`.

#### `cell.setFillColor`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `color` | string | yes | `^#[0-9A-Fa-f]{6}$` |

Returns `null`.

#### `cell.setBorders`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `edge` | string | yes | one of `all`, `DiagonalDown`, `DiagonalUp`, `Bottom`, `Left`, `Right`, `Top`, `InsideHorizontal`, `InsideVertical`. `all` applies to the four outer edges via 4 internal calls |
| `style` | string | yes | e.g. `Thin`, `Dashed`, `Double`, ... (not validated against an enum — passed through) |
| `color` | string | yes | `^#[0-9A-Fa-f]{6}$` |

Returns `null`.

#### `cell.setAlignHorizontal`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `align` | string | yes | one of `left`, `right`, `center`, `justify` |

Returns `null`.

### Conditional formatting

#### `cell.addColorScale`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `scaleType` | integer ≥2 | yes | 2 or 3 (two/three-color scale) |

Returns `boolean`.

#### `cell.addDatabar`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |

Returns `boolean`.

#### `cell.addIconSetCondition`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |

Returns `boolean`. No icon-set-type param — uses the underlying method's own default.

### Data validation and named ranges

#### `cell.addValidation`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet`, `range` | string | yes | |
| `type` | string | yes | real internal enum, e.g. `xlValidateWholeNumber`, `xlValidateDecimal`, `xlValidateList`, `xlValidateDate`, `xlValidateTime`, `xlValidateTextLength`, `xlValidateCustom`, `xlValidateInputOnly` |
| `operator` | string | yes | e.g. `xlBetween`, `xlNotBetween`, `xlEqual`, `xlNotEqual`, `xlLess`, `xlLessEqual`, `xlGreater`, `xlGreaterEqual` |
| `formula1` | string | yes, non-empty | |
| `formula2` | string | no (empty allowed) | |

Returns `true`. Throws if the type/operator is unrecognized or a validation already exists on the range.

#### `cell.addDefName`
| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes, non-empty | |
| `refersTo` | string | yes | e.g. `"Sheet1!$A$1:$A$5"` — the sheet name before `!` must exist |

Returns `true`. Throws `SCRIPT_EXCEPTION` for an invalid name (e.g. starting with a digit) or ref.

### AutoFilter

#### `cell.applyFilter`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |

Returns `null`. **Toggles** — calling this again on a sheet that already has a filter removes it.

#### `cell.getFilters`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes, non-empty |

Returns `boolean` — whether *any* AutoFilter exists on the sheet, not the filter criteria.

### PivotTable

Three separate calls: create+name, then add data fields by name.

#### `cell.addPivotTable`
| Field | Type | Required |
|---|---|---|
| `sourceSheet`, `sourceRange` | string | yes |
| `pivotSheet`, `pivotRange` | string | yes |
| `name` | string | yes, non-empty |

Returns `true`.

#### `cell.addPivotDataField`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet` | string | yes | sheet the pivot table lives on |
| `pivotName` | string | yes | from `addPivotTable`'s `name` |
| `field` | string | yes | source column name |
| `func` | string | yes | capitalized: `Sum`, `Average`, `Count`, `CountNumbers`, `Max`, `Min`, `Product`, `StdDev`, `StdDevP`, ... |

Returns `true`. Throws `SCRIPT_EXCEPTION` for an unknown `field`.

#### `cell.setPivotFieldFunction`
Same scope as `addPivotDataField`. Re-resolves an already-added data field and changes its aggregation function.

### Freeze panes

#### `cell.freezeAt`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |

Returns `null`. Freezing at `"A1"` effectively unfreezes.

### Insert images/OLE objects

`fromCol`/`colOffset`/`fromRow`/`rowOffset` position by cell + EMU offset within it, not a `range` string.

#### `cell.addImage`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet` | string | yes | |
| `imageSrc` | string | yes | URL or base64 data URI |
| `width`, `height` | integer ≥1 | yes | EMU |
| `fromCol`, `colOffset`, `fromRow`, `rowOffset` | integer ≥0 | yes | |

Returns `boolean`.

#### `cell.addOleObject`
Same placement fields as `addImage`, plus:
| Field | Type | Required |
|---|---|---|
| `data` | string | yes (empty allowed) |
| `appId` | string | yes, non-empty |

Returns `boolean`.

> **Not implemented**: `cell.addShape` — needs `ApiFill`/`ApiStroke` factory objects not confirmed in `sdkjs/cell/apiBuilder.js`; see §C11 of the test-design doc.

### Comments with replies

Comments are addressed by **id** (returned from `addComment`), not by range, for follow-up calls.

#### `cell.addComment`
| Field | Type | Required |
|---|---|---|
| `sheet`, `range` | string | yes |
| `text` | string | yes, non-empty |
| `author` | string | no (empty allowed) |

Returns the new comment's **id** (`string`).

#### `cell.addReply`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `commentId` | string | yes, non-empty |
| `text` | string | yes, non-empty |
| `author` | string | no |

Returns `null`.

#### `cell.setSolved`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `commentId` | string | yes, non-empty |
| `solved` | boolean | yes |

Returns `null`.

### Insert/delete rows and columns

Row/col indices are **0-based**.

#### `cell.insertEntireRow`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `rowIndex` | integer ≥0 | yes |

Returns `null`. New row inserted at `rowIndex`, shifting existing rows down.

#### `cell.deleteEntireColumn`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `colIndex` | integer ≥0 | yes |

Returns `null`.

### Recalculate formulas

#### `cell.recalculateAllFormulas`
No scope fields. Returns `boolean`.

### Charts and data series

`chartIndex` addresses into `ApiWorksheet.GetAllCharts()` — no `cell.getAllCharts` command is exposed separately since charts have no other addressable identity.

#### `cell.addSeria`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet` | string | yes | |
| `chartIndex` | integer ≥0 | yes | |
| `valuesRange` | string | yes | e.g. `"Sheet1!B1:B10"` |

Returns `null`.

#### `cell.setSeriaName`
| Field | Type | Required |
|---|---|---|
| `sheet` | string | yes |
| `chartIndex` | integer ≥0 | yes |
| `seriaIndex` | integer ≥0 | yes |
| `name` | string | yes, non-empty |

Returns `boolean`.

### SmartArt

#### `cell.getSmartArtClassType`
| Field | Type | Required | Notes |
|---|---|---|---|
| `sheet` | string | yes | |
| `index` | integer ≥0 | yes | indexes the sheet's generic drawing collection, not a SmartArt-only list |

Returns the object's class type (`string`). Throws `SCRIPT_EXCEPTION` if `index` is out of range.

---

## 5. Slide commands (`slide.*` / `presentation.*`)

### Slide management

#### `slide.addSlide`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | out-of-range silently appends at the end instead of erroring |

Returns `null`.

#### `slide.removeSlides`
| Field | Type | Required | Notes |
|---|---|---|---|
| `start` | integer ≥0 | yes | |
| `count` | integer ≥1 | yes | **contiguous range**, not an arbitrary index list |

Returns `true`. Throws `SCRIPT_EXCEPTION` if `start`/`count` is out of range.

#### `slide.duplicate`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |

Returns `boolean`.

#### `slide.moveTo`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |
| `newIndex` | integer ≥0 | yes |

Returns `boolean`.

### Enumerate slide content

#### `slide.getAllShapes` / `slide.getAllImages` / `slide.getAllTables` / `slide.getAllCharts`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |

Each returns an array of **0-based indices** into that slide's collection (used by `shapeIndex`/`tableIndex` elsewhere).

### Layouts and masters

> `slide.applyTheme` and `slide.setBackground` are **not implemented** — see §D3/§D4 of the test-design doc for why.

#### `slide.getLayout`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |

Returns `boolean` — whether the slide has a layout.

#### `slide.applyLayout`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | target slide |
| `fromIndex` | integer ≥0 | yes | slide to **borrow** the layout from |

Returns `boolean`. There is no id-based layout lookup — this reuses another slide's already-resolved layout.

#### `slide.addMaster`
| Field | Type | Required |
|---|---|---|
| `position` | integer ≥0 | yes |

Returns `boolean`. Uses the presentation's existing theme (or the current default) — no theme param.

### Shapes/text boxes with positioning

#### `slide.createShape`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | |
| `type` | string | yes, non-empty | shape preset name, e.g. `"rect"` |
| `x`, `y`, `width`, `height` | integer | yes | EMU |

Returns `true`.

#### `slide.setPosition`
| Field | Type | Required |
|---|---|---|
| `index`, `shapeIndex` | integer ≥0 | yes |
| `x`, `y` | integer | yes |

Returns `null`.

#### `slide.setRotation`
| Field | Type | Required |
|---|---|---|
| `index`, `shapeIndex` | integer ≥0 | yes |
| `degrees` | integer | yes |

Returns `boolean`.

#### `slide.setSize`
| Field | Type | Required |
|---|---|---|
| `index`, `shapeIndex` | integer ≥0 | yes |
| `width`, `height` | integer ≥0 | yes |

Returns `null`.

### Text formatting

Shares the underlying `ApiRun` class with Word — same semantics as `word.setBold`/`word.setFontFamily`, different target-resolution path.

#### `slide.setBold`
| Field | Type | Required |
|---|---|---|
| `index`, `shapeIndex`, `paraIndex`, `runIndex` | integer ≥0 | yes |
| `bold` | boolean | yes |

Returns `null`.

#### `slide.setFontFamily`
Same index fields as `setBold`, plus `font: string` (non-empty). Returns `null`.

### Insert images

#### `slide.createImage`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | |
| `imageSrc` | string | yes, non-empty | URL or base64 data URI |
| `x`, `y`, `width`, `height` | integer | yes | EMU |

Returns `true`.

### Table editing

> `slide.createTable` is **not implemented** — no public API to target an arbitrary slide as "current" before creating a table; see §D8.

#### `slide.addRow`
| Field | Type | Required |
|---|---|---|
| `index`, `tableIndex` | integer ≥0 | yes |

Returns `boolean`.

#### `slide.mergeCells`
| Field | Type | Required |
|---|---|---|
| `index`, `tableIndex` | integer ≥0 | yes |
| `fromRow`, `fromCol`, `toRow`, `toCol` | integer ≥0 | yes |

Returns `null`. Throws on a failed merge.

### Speaker notes

#### `slide.addNotesText`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |
| `text` | string | yes, non-empty |

Returns `boolean`. **Appends** — calling twice concatenates both texts with no separator.

#### `slide.getNotesText`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |

Returns the notes text (`string`), or `""` if no notes exist.

### Comments

#### `slide.addComment`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |
| `x`, `y` | integer | yes | EMU position |
| `text` | string | yes, non-empty |
| `author` | string | no (empty allowed) |

Returns `boolean`.

#### `presentation.getAllComments`
No scope fields. Returns `[{text: string, author: string}, ...]` across the whole presentation.

### Transitions

#### `slide.setTransition`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | |
| `entryEffect` | string | yes, non-empty | e.g. `"effectFade"`, `"effectNone"` — throws `SCRIPT_EXCEPTION` if unrecognized |
| `duration` | integer ≥0 | yes | milliseconds |

Returns `boolean`.

### Document properties

#### `presentation.getDocumentInfo`
No scope fields. Returns a plain object directly (already JSON-safe):
```json
{"Application":"...", "Created":"...", "LastModified":"...", "LastModifiedBy":"...", "Authors":["..."], "Title":"...", "Tags":"...", "Subject":"...", "Comment":"..."}
```

#### `presentation.getCustomProperty`
| Field | Type | Required |
|---|---|---|
| `name` | string | yes, non-empty |

Returns the property's value, or `null` if not set.

---

## 6. PDF commands (`pdf.*`)

Unlike Word/Cell/Slide, most PDF commands take a `page` field (0-based index) since PDF content is addressed per-page via `ApiDocument.GetPage(nPos)`, not per-document — an out-of-range `page` throws `SCRIPT_EXCEPTION`.

### Form field read/write

#### `pdf.getAllFields`
No scope fields. Returns an array of field **names** (`ApiField.GetFullName()`), not object handles — these names are what `key` elsewhere in this section expects.
```json
{"command":"pdf.getAllFields","scope":{}}
→ {"ok":true,"result":["Name","Total","Agree"]}
```

#### `pdf.getFieldValue`
| Field | Type | Required |
|---|---|---|
| `key` | string | yes, non-empty |

Returns the field's value. Throws `SCRIPT_EXCEPTION` if `key` doesn't name a real field.

#### `pdf.setFieldValue`
| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes, non-empty | |
| `value` | string | yes (empty allowed) | `SetValue` stringifies its argument — a checkbox's checked state is the export string `"Yes"`/`"Off"`, not a JSON boolean |

Throws `SCRIPT_EXCEPTION` if `key` doesn't name a real field.
```json
{"command":"pdf.setFieldValue","scope":{"key":"Total","value":"500.00"}}
→ {"ok":true,"result":"500.00"}
```

### Annotations

`rect` throughout this section is a flat `[x1,y1,x2,y2]` array with `x1<x2` and `y1<y2` — reject anything else client-side, the schema check only verifies shape (4 numbers), not the ordering invariant; a degenerate rect surfaces as `SCRIPT_EXCEPTION`.

#### `pdf.getAllAnnots`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |

Returns an array of annotation class-type strings (`ApiBaseAnnotation.GetClassType()`), one per annotation currently on the page — the only allowlisted way to verify the `pdf.add*` commands below took effect.

#### `pdf.addHighlight` / `pdf.addUnderline` / `pdf.addStrikeout`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |
| `rect` | `[number,number,number,number]` | yes |

Returns `true`.
```json
{"command":"pdf.addHighlight","scope":{"page":0,"rect":[10,10,100,20]}}
→ {"ok":true,"result":true}
```

#### `pdf.addFreeText`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |
| `rect` | `[number,number,number,number]` | yes |
| `text` | string | yes (empty allowed) |

Returns `true`.

#### `pdf.addInk`
| Field | Type | Required | Notes |
|---|---|---|---|
| `page` | integer ≥0 | yes | |
| `rect` | `[number,number,number,number]` | yes | bounding box |
| `paths` | array of paths, each an array of `[x,y]` pairs | yes, non-empty | e.g. `[[[10,10],[20,20],[30,10]]]` — converted internally to the `{x,y}` object shape `CreateInkAnnot` actually requires |

Returns `true`.
```json
{"command":"pdf.addInk","scope":{"page":0,"rect":[10,10,40,40],"paths":[[[10,10],[20,20],[30,10]]]}}
→ {"ok":true,"result":true}
```

#### `pdf.addStamp` — **not implemented**
`Api.CreateStampAnnot(rect, type, author, creationDate)` requires `type` to be a value from `AscPDF.STAMP_TYPES`; that enum's definition wasn't locatable in the vendored `sdkjs` source, so this command is deliberately absent from the allowlist rather than guessed. See §7 below.

### Text search / selection / extraction

#### `pdf.searchText`
| Field | Type | Required | Notes |
|---|---|---|---|
| `page` | integer ≥0 | yes | |
| `text` | string | yes, non-empty | |
| `matchCase` | boolean | no, default `false` | |
| `wholeWords` | boolean | no, default `false` | |

Returns an array of `Quad`s — each already a flat 8-number tuple `[x1,y1,x2,y2,x3,y3,x4,y4]` (top-left → top-right → bottom-left → bottom-right), one per match. Empty array if nothing matches (not an error).

#### `pdf.setSelection`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |
| `startPoint` | `{x: number, y: number}` | yes |
| `endPoint` | `{x: number, y: number}` | yes |

Returns `boolean`. Must be called before `pdf.getSelectedText` has anything to return.

#### `pdf.getSelectedText`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |

Returns the currently-selected text (`string`, possibly empty if nothing is selected). Takes no rect/range — it reads whatever selection is already active on the page, set via `pdf.setSelection`.
```json
{"command":"pdf.setSelection","scope":{"page":0,"startPoint":{"x":10,"y":10},"endPoint":{"x":50,"y":20}}}
→ {"ok":true,"result":true}
{"command":"pdf.getSelectedText","scope":{"page":0}}
→ {"ok":true,"result":"Total"}
```

#### `pdf.recognizeContent`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |

Recognizes page content (e.g. an image-only page) into editable drawing objects and returns their class-type strings (one per newly recognized drawing) — this is content recognition, not OCR-to-text.

### Redaction

Two-step workflow: `pdf.addRedact`/`pdf.searchAndRedact` only *mark* content as pending redaction; `pdf.applyRedact` is what actually removes it, document-wide (there is no per-page apply).

#### `pdf.addRedact`
| Field | Type | Required |
|---|---|---|
| `page` | integer ≥0 | yes |
| `rect` | `[number,number,number,number]` | yes |

Returns `true`. Creates a pending redact annotation; does not remove content by itself.

#### `pdf.searchAndRedact`
| Field | Type | Required | Notes |
|---|---|---|---|
| `text` | string | yes, non-empty | |
| `matchCase` | boolean | no, default `false` | |
| `wholeWords` | boolean | no, default `false` | |

Document-wide (no `page` field). Marks every match as pending redact and returns the number marked (`integer`).
```json
{"command":"pdf.searchAndRedact","scope":{"text":"SSN:"}}
→ {"ok":true,"result":2}
```

#### `pdf.applyRedact`
No scope fields. Strips all currently-pending redactions across the whole document. Returns `true`. Throws `SCRIPT_EXCEPTION` ("Has no redact to apply") if nothing is pending.

### Page operations

#### `pdf.getPageCount`
No scope fields. Returns the document's page count (`integer`).

#### `pdf.addPage`
| Field | Type | Required | Notes |
|---|---|---|---|
| `index` | integer ≥0 | yes | position to insert at; clones the size of the page at `index-1` (or `index`) |

Returns the new page's index (`integer`).
```json
{"command":"pdf.addPage","scope":{"index":1}}
→ {"ok":true,"result":1}
```

#### `pdf.removePage`
| Field | Type | Required |
|---|---|---|
| `index` | integer ≥0 | yes |

Returns `true`. Throws `SCRIPT_EXCEPTION` if `index` is out of range (the underlying API returns `false` rather than throwing; the command script converts this to a thrown error for the same `SCRIPT_EXCEPTION` contract used everywhere else in this reference).

---

## 7. Not-yet-implemented commands (reference)

These are documented in the plan/test-design docs but deliberately absent from the allowlist because their backing API needs a factory or capability not yet confirmed in the vendored `sdkjs` source. Calling them returns `NOT_ALLOWLISTED`.

| Command | Blocked on |
|---|---|
| `word.addCheckBoxForm` | No confirmed insertion API for a created `ApiCheckBoxForm`. |
| `cell.addShape` | `ApiFill`/`ApiStroke` factory not confirmed in `sdkjs/cell/apiBuilder.js`. |
| `slide.applyTheme` | `Api.CreateTheme` needs three further factory-built scheme objects not confirmed. |
| `slide.setBackground` | No solid-fill factory confirmed in `sdkjs/slide/apiBuilder.js`. |
| `slide.createTable` | No public API to target an arbitrary slide as "current" before table creation. |
| `pdf.addStamp` | `Api.CreateStampAnnot`'s `type` parameter requires a value from `AscPDF.STAMP_TYPES`; that enum's definition wasn't locatable in the vendored `sdkjs` source. |

---

## 8. MCP service (`eo-mcp`)

`desktop-apps/win-linux/tools/eo-mcp/` — a thin MCP wrapper, spawned by an MCP host over
stdio, talking directly to the gateway's Unix socket (not through `eo-ctl`). Three
tools, a near-direct translation of §1/§2 above — see the design rationale in
`~/repos/eo-mcp-service-plan.md` and usage in `tools/eo-mcp/README.md`:

| Tool | Params | Wraps |
|---|---|---|
| `gateway_connect` | `file: string` | `eo-ctl connect`'s resolution algorithm, reimplemented client-side in JS (`gatewayClient.js`'s `connectFile`/`connectAndResolveViewId`) since it drives its own `child_process.spawn`, not `eo-ctl` as a subprocess. |
| `gateway_call` | `command: string, scope: object, targetViewId: integer` | One gateway command call. |
| `gateway_list_commands` | *(none)* | `gateway.listCommands`. |
