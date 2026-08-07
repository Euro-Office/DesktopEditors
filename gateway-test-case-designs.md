# Gateway Command Test Case Designs

## Scope of this document

Per [cdp-gateway-cli-plan.md](cdp-gateway-cli-plan.md), the CLI (`eo-ctl`) and the external wire protocol (`GatewayServer`'s auth + framing) are both thin shells around one shared internal call:

```
GatewayCommandRunner::Execute(commandName: string, scope: JSON) -> Result | Error
```

All test cases below call `Execute()` **directly, in-process**, bypassing the socket, the wire framing, and the auth-token check — those belong to the `GatewayServer` shell and are covered once, separately, in §A6 (shell-boundary smoke tests), not repeated per command. Every functional test case is therefore identical whether it's exercised by the CLI or the external gateway — that's the point of testing at this layer.

Each test case is specified as: **Setup** (document fixture state before the call) → **Input** (command name + scope) → **Expected** (the assertion against document state / CDP-observable result / error shape) → **Type** (positive / negative). "Actual" is intentionally left blank — it's filled in at execution time, not design time.

Tests are grouped in the same order as the implementation plan: cross-cutting dispatch tests once, then Word → Cell → Slide → PDF, one section per command family.

---

## A. Cross-cutting dispatch-layer tests (run once; apply generically to *any* command — do not re-derive per command below)

These validate `GatewayCommandRunner` itself, independent of which command is invoked. Use any single already-implemented command (e.g. `word.getTitle`) as the vehicle.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| A1 | Document open, empty title | `command="not.a.real.command"`, `scope={}` | `Error{code: NOT_ALLOWLISTED}`; no CDP `Runtime.evaluate` call is issued (assert via CDP-call spy/count == 0) | Negative |
| A2 | Document open | `command="word.setBold"`, `scope={}` (missing required `paraIndex`/`runIndex`/`bold`) | `Error{code: SCHEMA_INVALID}`; rejected before any CDP dispatch (spy count == 0) | Negative |
| A3 | Document open | `command="word.setBold"`, `scope={"paraIndex":"zero","runIndex":2,"bold":true}` (wrong type) | `Error{code: SCHEMA_INVALID}`; no CDP dispatch | Negative |
| A4 | Document open | `command="word.setBold"`, `scope={"paraIndex":0,"runIndex":2,"bold":true,"__proto__":"x"}` (unexpected/extra field) | `Error{code: SCHEMA_INVALID}` if schema declares `additionalProperties:false` (decide this at implementation time; if allowed, assert the extra field is silently dropped from what reaches the script, never used) | Negative |
| A5 | No document open / document handle stale | `command="word.getTitle"`, `scope={}` | `Error{code: TARGET_NOT_FOUND}`; no CDP dispatch attempted against a dead target | Negative |
| A6 | Document open, command deliberately made to throw inside the JS (e.g. call `word.setBold` with an out-of-range `paraIndex` that the script itself throws on rather than the schema catching) | valid schema, but semantically invalid `scope` | `Error{code: SCRIPT_EXCEPTION, message: <propagated CDP exception text>}`; process does not crash, subsequent calls on the same runner still succeed (runner is not left in a broken state) | Negative |
| A7 | Two sequential valid calls, second depending on first's effect | e.g. `word.setTitle{title:"A"}` then `word.getTitle{}` | second call's result reflects the first call's effect (`"A"`) — confirms state is truly persisted in the document, not just returned from a stub | Positive |
| A8 (shell-boundary smoke test, not part of the bypass suite — run once against the real `GatewayServer`, not `Execute()` directly) | Gateway running, valid token | connect over configured transport, send `word.getTitle` with **wrong** token | connection rejected / `Error{code: UNAUTHENTICATED}` before `Execute()` is ever reached | Negative |
| A9 (same shell-boundary tier as A8) | Gateway running, valid token | connect, send `word.getTitle` with correct token | response matches exactly what `Execute("word.getTitle", {})` returns when called in-process — proves the shell adds nothing/changes nothing | Positive |

---

## B. Word

Fixture convention: "blank doc" = a fresh in-memory document with one empty paragraph. "3-para doc" = a fixture with 3 paragraphs of known text, referenced across the whole Word section for reuse.

### B1. Document properties

Backing API confirmed by reading `sdkjs/word/apiBuilder.js` directly (not assumed): `ApiCore.prototype.SetTitle/GetTitle` (`Api.GetDocument().GetCore()`), `ApiCustomProperties.prototype.Add(name, value)`/`Get(name)` (`Api.GetDocument().GetCustomProperties()`, singular get/add — there is **no** `GetAll` on `ApiCustomProperties`, so B1.3's originally-planned `getCustomProperties` returning a map, and B1.5's `getAuthor`, don't correspond to a real method; both are corrected below rather than implemented against a fabricated API, per repo's anti-speculation rule.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B1.1 | Blank doc, no title set | `word.setTitle{title:"Q3 Report"}` | returns `null`; subsequent `word.getTitle{}` returns `"Q3 Report"` | Positive |
| B1.2 | Blank doc | `word.setTitle{title:""}` | empty string accepted; title reads back as `""` | Positive (boundary) |
| B1.3 | Blank doc | `word.setCustomProperty{name:"Reviewed", value:"true"}` then `word.getCustomProperty{name:"Reviewed"}` | returns `"true"` | Positive |
| B1.4 | Blank doc | `word.setCustomProperty{name:"", value:"x"}` | `Error{code: SCHEMA_INVALID}` (empty name rejected by the command's own scope schema, `RequireString(..., allowEmpty=false)`) | Negative |
| B1.5 | Blank doc, property never set | `word.getCustomProperty{name:"NoSuchProp"}` | returns `null` (matches `ApiCustomProperties.Get`'s own documented "or null if the property does not exist" contract) — not an error | Positive (boundary) |

### B2. Content enumeration

Backing API confirmed in `sdkjs/word/apiBuilder.js`: `ApiDocument.prototype = Object.create(ApiDocumentContent.prototype)` (`apiBuilder.js:3112`), so `Api.GetDocument().GetAllParagraphs()/GetAllTables()/GetAllDrawingObjects()/GetAllCharts()` are the real, inherited methods (`ApiDocumentContent.prototype.GetAll*`, `apiBuilder.js:6193-6289`). Each returns an array of `Api*` **object instances** (`ApiParagraph`, `ApiTable`, ...), which are not themselves JSON-serializable over CDP's `returnByValue` — attempting to return them directly comes back as `{}` per element, not usable. Each command below therefore returns **an array of 0-based indices** (`array.map(function(_, idx){ return idx; })`), the same index space `paraIndex`/`tableIndex`/etc. scope fields elsewhere in this document already use — not the original design's "paragraph handles", which was never a concrete wire shape to begin with.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B2.1 | 3-para doc | `word.getAllParagraphs{}` | returns `[0,1,2]` | Positive |
| B2.2 | Blank doc + 1 table inserted via fixture setup | `word.getAllTables{}` | returns `[0]` | Positive |
| B2.3 | Blank doc, no drawings | `word.getAllDrawingObjects{}` | returns `[]` (not an error, not null) | Positive (boundary) |
| B2.4 | Blank doc, no charts | `word.getAllCharts{}` | returns `[]` | Positive (boundary) |

### B3. Insert/edit text

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B3.1 | Blank doc | `word.addText{paraIndex:0, text:"Hello"}` | `word.getAllParagraphs{}`[0] text == `"Hello"` | Positive |
| B3.2 | Blank doc | `word.addText{paraIndex:5, text:"x"}` (index beyond paragraph count) | `Error{code: SCRIPT_EXCEPTION}` (out-of-range) | Negative |
| B3.3 | 3-para doc, para 1 has text "abc" | `word.getText{paraIndex:1, runIndex:0}` | returns `"abc"` | Positive |
| B3.4 | Blank doc | `word.addText{paraIndex:0, text:""}` | accepted, no-op text change, doc still has 1 run with `""` (or no new run — pin down expected behavior at implementation, test locks it) | Positive (boundary) |
| B3.5 | Blank doc | `word.addText{paraIndex:0, text:"😀 multi-byte"}` | text round-trips exactly (UTF-8/UTF-16 boundary not corrupted) | Positive (boundary) |

### B4. Character formatting

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B4.1 | Doc with 1 run, bold=false | `word.setBold{paraIndex:0, runIndex:0, bold:true}` | run's bold state reads back `true` via a corresponding `getRunProperties` read (or CDP-observable formatting check) | Positive |
| B4.2 | Doc with 1 run | `word.setItalic{paraIndex:0, runIndex:0, italic:true}` | italic reads back `true` | Positive |
| B4.3 | Doc with 1 run | `word.setFontFamily{paraIndex:0, runIndex:0, font:"Arial"}` | font reads back `"Arial"` | Positive |
| B4.4 | Doc with 1 run | `word.setFontFamily{paraIndex:0, runIndex:0, font:"NotARealFontXYZ"}` | accepted (document-level font substitution is a rendering concern, not a gateway validation concern) — confirms the gateway doesn't over-validate into rendering territory | Positive (boundary) |
| B4.5 | Doc with 1 run | `word.setColor{paraIndex:0, runIndex:0, color:"#FF0000"}` | color reads back as `#FF0000` | Positive |
| B4.6 | Doc with 1 run | `word.setColor{paraIndex:0, runIndex:0, color:"not-a-color"}` | `Error{code: SCHEMA_INVALID}` (schema should constrain color to a hex pattern) | Negative |

### B5. Paragraph formatting

Backing API confirmed in `sdkjs/word/apiBuilder.js`: `ApiParagraph.GetParaPr()` (line 10253) returns the `ApiParaPr`; `SetJc/SetSpacingBefore/SetIndLeft` (lines 16677, 16863, 16580) all take **twips** (1/1440 inch, called `twips` in the method's own doc comment), not points — corrected the scope field name from the originally-planned `points` to `twips` to match, per the naming rule against disinformation.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B5.1 | 1-para doc, default alignment | `word.setJc{paraIndex:0, align:"center"}` | alignment reads back `"center"` | Positive |
| B5.2 | 1-para doc | `word.setJc{paraIndex:0, align:"diagonal"}` (not a valid enum value) | `Error{code: SCHEMA_INVALID}` (schema constrains to left/right/center/both, the exact enum `ApiParaPr.SetJc` itself accepts) | Negative |
| B5.3 | 1-para doc | `word.setSpacingBefore{paraIndex:0, twips:240}` | spacing-before reads back `240` twips (12pt) | Positive |
| B5.4 | 1-para doc | `word.setIndLeft{paraIndex:0, twips:-100}` | negative indent accepted (valid Word behavior — hanging indent; `SetIndLeft` does no sign check itself) | Positive (boundary) |

### B6. Search & replace

Backing API confirmed: `ApiDocument.Search(sText, isMatchCase)` (`apiBuilder.js:8253`) returns an array of `ApiRange` objects, not JSON-serializable over `returnByValue` (same issue as §B2) -- returns the **match count** instead, matching this document's established pattern of exposing lengths/indices rather than unserializable object handles. `ApiDocument.SearchAndReplace(oProperties)` (`apiBuilder.js:7598`) takes `{searchString, replaceString, matchCase=true}`.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B6.1 | 3-para doc, one paragraph contains "foo" | `word.search{text:"foo"}` | returns `1` | Positive |
| B6.2 | 3-para doc, "foo" appears twice | `word.search{text:"foo"}` | returns `2` | Positive |
| B6.3 | 3-para doc containing "foo" | `word.searchAndReplace{find:"foo", replace:"bar"}` | subsequent `word.search{text:"foo"}` returns `0`; `word.search{text:"bar"}` returns the count "foo" had before the replace | Positive |
| B6.4 | 3-para doc, no "zzz" anywhere | `word.search{text:"zzz"}` | returns `0`, not an error | Positive (boundary) |

### B7. Table creation and editing

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B7.1 | Doc with 1 table, 2x2 | `word.addRow{tableIndex:0, rowIndex:1}` | table now has 3 rows; new row has 2 empty cells | Positive |
| B7.2 | Doc with 1 table, 2x2 | `word.addColumn{tableIndex:0, colIndex:1}` | table now has 3 columns on every row | Positive |
| B7.3 | Doc with 1 table, 2x2 | `word.mergeCells{tableIndex:0, fromRow:0, fromCol:0, toRow:0, toCol:1}` | resulting table reports the merged cell as a single cell spanning 2 columns | Positive |
| B7.4 | Doc with 1 table, 2x2 | `word.mergeCells{tableIndex:0, fromRow:0, fromCol:0, toRow:5, toCol:5}` (out of range) | `Error{code: SCRIPT_EXCEPTION}` | Negative |
| B7.5 | Doc with 1 table | `word.setStyle{tableIndex:0, styleId:"TableGrid"}` | table's style reads back `"TableGrid"` | Positive |

### B8. Style creation and application

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
Backing API confirmed: `ApiDocument.CreateStyle(sStyleName, sType)` (`apiBuilder.js:7106`) and `ApiDocument.GetStyle(sStyleName)` (`apiBuilder.js:7091`, returns `new ApiStyle(oStyles.Get(oStyleId))` — `.Style` is `undefined` when no such style exists, since `ApiStyle`'s constructor (`apiBuilder.js:3549`) just assigns its argument verbatim). `word.getStyle` therefore returns the JSON-safe boolean `!!style.Style` rather than the unserializable `ApiStyle` handle itself, consistent with this document's established pattern (§B2, §B6). `ApiStyle.SetTextPr(textPr)` (`apiBuilder.js:15424`) requires an actual `ApiTextPr` instance, constructed via `Api.CreateTextPr()` (`apiBuilder.js:27443`) then configured (e.g. `.SetBold`, `apiBuilder.js:15704`) before being passed in — resolved answer decided below rather than left open, since implementing it required picking one anyway.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B8.1 | Blank doc, no custom styles | `word.createStyle{name:"MyHeading", type:"paragraph"}` | `word.getStyle{name:"MyHeading"}` returns `true` | Positive |
| B8.2 | Style "MyHeading" already created | `word.createStyle{name:"MyHeading", type:"paragraph"}` (duplicate) | succeeds idempotently — `CreateStyle`'s own doc comment states an existing style of the same name "will be replaced with a new one", confirmed in source, not assumed | Positive |
| B8.3 | Style exists, 1-para doc | `word.setStyleTextPr{styleId:"MyHeading", bold:true}` | returns `null`; the style's text properties now carry bold (verified via a subsequent `word.setBold`-style read on a paragraph with that style applied, at the §6 build/deploy gate — this harness's schema-validation tests can't apply a paragraph style, only set the style's own properties) | Positive |

### B9. Insert images/shapes with positioning

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
Backing API confirmed: `Api.CreateImage(imageSrc, width, height)` (`apiBuilder.js:4674`) documents `imageSrc` as "currently only internet URL or Base64 encoded images are supported" — **not** an arbitrary local file path, correcting this section's original `path` fixture design. `width`/`height` are EMU (English Metric Units), not pixels. `ApiParagraph.AddDrawing` (`apiBuilder.js:10486`) inserts the created `ApiImage` (which extends `ApiDrawing`, `apiBuilder.js:3665`) into a paragraph — `paraIndex` added to the scope below since the original design omitted a target paragraph entirely. `ApiDrawing.SetWrappingStyle`/`SetHorPosition` (`apiBuilder.js:18651,18771`) operate on a resolved drawing, indexed the same way as `word.getAllDrawingObjects` (§B2).

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B9.1 | Blank doc, valid base64-encoded PNG fixture | `word.createImage{paraIndex:0, imageSrc:"data:image/png;base64,<fixture>", width:914400, height:914400}` (1x1 inch, 914400 EMU/inch) | `word.getAllDrawingObjects{}` length increases by 1 | Positive |
| B9.2 | Blank doc | `word.createImage{paraIndex:0, imageSrc:"not-a-valid-data-uri-or-url", width:914400, height:914400}` | `Error{code: SCRIPT_EXCEPTION}` — `createImage`'s underlying loader rejects an unrecognized source at load time, not at the gateway's schema layer (schema only constrains shape: non-empty string, positive EMU) | Negative |
| B9.3 | Doc with 1 image | `word.setWrappingStyle{drawingIndex:0, style:"square"}` | returns `true` | Positive |
| B9.4 | Doc with 1 image | `word.setHorPosition{drawingIndex:0, distanceEmu:200000, relativeTo:"page"}` | returns `true` | Positive |

### B10. Headers/footers, page setup

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
Backing API confirmed: `ApiDocument` has no `GetSection(index)` -- only `GetFinalSection()` (`apiBuilder.js:7191`), so `sectionIndex` from the original design doesn't correspond to a real accessor; these commands operate on the document's one final section only (correct for every fixture in this document, which are all single-section). `ApiSection.GetHeader(sType, isCreate)` (`apiBuilder.js:13289`) returns an `ApiDocumentContent`, which has no direct `AddText` -- populated via `Api.CreateParagraph()` (`apiBuilder.js:4575`) + `ApiParagraph.AddText` (§B3) + `ApiDocumentContent.AddElement(0, paragraph)` (`apiBuilder.js:6052`). `SetPageMargins`/`SetPageSize` (`apiBuilder.js:13181,13141`) take twips, matching §B5's unit correction.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B10.1 | Blank doc, default section | `word.setHeaderText{type:"default", text:"Confidential"}` | returns `null`; the section's default header now contains a paragraph with that text (verified at the §6 build/deploy gate, since reading it back needs the same unserializable-`ApiDocumentContent` problem as §B2/§B6 worked around for reads, not writes) | Positive |
| B10.2 | Blank doc | `word.setPageMargins{left:1440, top:1440, right:1440, bottom:1440}` (1 inch each) | returns `true` | Positive |
| B10.3 | Blank doc | `word.setPageSize{width:0, height:0}` (zero/degenerate size) | `Error{code: SCHEMA_INVALID}` (schema sets `minimum:1` on both) | Negative |

### B11. Bookmarks and hyperlinks

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
Backing API confirmed: `ApiDocument.GetBookmark` (`apiBuilder.js:8907`) exists, but bookmark *creation* is only on `ApiRange.AddBookmark` (`apiBuilder.js:1581`), not `ApiParagraph` directly -- resolved via `ApiParagraph.GetRange(0, 0)` (a real, existing method). `ApiParagraph.AddHyperlink(sLink, sScreenTipText, sBookmarkName)` (`apiBuilder.js:10578`) does **not** take display text as a parameter at all -- it calls `this.Paragraph.SelectAll(1)` internally and wraps whatever text is *already in the paragraph* as the hyperlink, rather than inserting new "link"-labeled text. Corrected `word.addHyperlink` to add the text first (`ApiParagraph.AddText`, §B3) then wrap it, rather than assuming a `text` parameter the underlying method doesn't have. `getBookmark` returns a boolean (same unserializable-handle pattern as §B6/§B8) rather than "non-null".

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B11.1 | 1-para doc | `word.addBookmark{paraIndex:0, name:"section1"}` | returns `null`; `word.getBookmark{name:"section1"}` returns `true` | Positive |
| B11.2 | 1-para doc, empty | `word.addHyperlink{paraIndex:0, text:"link", url:"https://example.com"}` | paragraph now contains text "link" wrapped in a hyperlink pointing at the URL (verified at the §6 build/deploy gate — reading the hyperlink target back hits the same unserializable-object-return problem as other reads in this document, not solvable from the schema-validation harness alone) | Positive |
| B11.3 | 1-para doc | `word.addHyperlink{paraIndex:0, text:"link", url:"javascript:alert(1)"}` | rejected — `Error{code: SCHEMA_INVALID}` (the command's own scope schema restricts URL scheme to http/https/mailto as defense-in-depth, independent of whatever scheme handling `AddHyperlink` does internally) | Negative (security) |

### B12. Fillable form fields / content controls

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
Backing API confirmed: text-form insertion has a real, documented, purpose-built method -- `ApiDocument.InsertTextForm(formPr)` (`sdkjs-forms/apiBuilder.js:452`), which inserts at the current cursor/selection, positioned first via `ApiRange.Select()` (`sdkjs/word/apiBuilder.js:1737`) on `paragraph.GetRange(0,0)`. `ApiDocument.GetAllForms`/`SetFormsData` (`apiBuilder.js:8613,7963`) confirmed; `SetFormsData` takes `Array<{key, value}>` (`FormData` typedef, `apiBuilder.js:7876`), so `word.setFormsData`'s `data` object is converted to that array shape. `getAllForms` returns form keys (via `ApiFormBase.GetFormKey()`, `apiBuilder.js:25123`) rather than the unserializable `ApiForm` handles, same pattern as elsewhere in this document.

**Checkbox-form insertion (`word.addCheckBoxForm`, B12.4) is deferred, not guessed.** `Api.CreateCheckBoxForm(formPr)` exists (`sdkjs-forms/apiBuilder.js:213`), but unlike text forms there is no equivalent `ApiDocument.InsertCheckBoxForm` documented insertion method in the vendored source -- inserting the raw content control it produces would require reaching into `ApiParagraph.AddInlineLvlSdt`'s private push mechanism in a way that isn't confirmed to work (its own `instanceof ApiInlineLvlSdt` type guard would reject an `ApiCheckBoxForm`). Rather than ship an unverified insertion path, B12.4 stays unimplemented until a real insertion method is found or confirmed with the SDK maintainers -- flagged here as an open item, not silently dropped.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B12.1 | Blank doc | `word.addTextForm{key:"name", paraIndex:0}` | returns `null`; `word.getAllForms{}` returns `["name"]` | Positive |
| B12.2 | Doc with 1 text form, key "name" | `word.setFormsData{data:{"name":"Alice"}}` | returns `true` (re-reading the form's value needs `GetFormsData`, not currently an allowlisted command -- add it if this read-back becomes necessary at the §6 build/deploy gate) | Positive |
| B12.3 | Doc with 1 text form, key "name" | `word.setFormsData{data:{"doesNotExist":"x"}}` | `SetFormsData`'s own implementation (`apiBuilder.js:7963`) only requires `arrData` to be an array -- an unknown key inside it is not itself checked, so this is a no-op that still returns `true`, not an error. Decision resolved by reading the source rather than left open. | Positive |
| B12.4 | *(deferred -- see note above)* | `word.addCheckBoxForm{...}` | not implemented in this pass | Deferred |

### B13. Comments and track changes

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| B13.1 | 1-para doc | `word.addComment{paraIndex:0, text:"needs review", author:"peter"}` | `word.getAllComments{}` length == 1, matching text/author | Positive |
| B13.2 | Blank doc, revisions off | `word.setTrackRevisions{enabled:true}` then `word.addText{paraIndex:0, text:"new"}` | the inserted text is recorded as a tracked insertion (revision present), not a plain edit | Positive |
| B13.3 | Doc with pending tracked changes | `word.acceptAllRevisionChanges{}` | no pending revisions remain; content reflects the accepted state | Positive |
| B13.4 | Doc, no comments | `word.getAllComments{}` | returns empty array, not an error | Positive (boundary) |

---

## C. Cell (Spreadsheet)

Fixture convention: "1-sheet wb" = workbook with a single sheet "Sheet1", A1:C3 empty.

### C1. Sheet management

Backing API confirmed in `sdkjs/cell/apiBuilder.js`: `Api.AddSheet(sName)` (777, top-level `Api`, not `ApiWorkbook`) throws if `Api.GetSheet(sName)` already resolves a sheet with that name; `Api.GetSheets()`/`ApiWorkbook.GetSheets()` (799, 8173) return `ApiWorksheet[]`, not serializable directly -- `cell.getSheets` returns an array of names via `ApiWorksheet.GetName()` (8546), same established pattern. `ApiWorksheet.SetActive()` (8332) is on the worksheet, not `ApiWorkbook.SetActiveSheet`. `Api.GetSheet(nameOrIndex)` (867) resolves a sheet by name for target resolution.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C1.1 | 1-sheet wb | `cell.addSheet{name:"Data"}` | returns `null`; `cell.getSheets{}` returns `["Sheet1","Data"]` | Positive |
| C1.2 | 1-sheet wb | `cell.addSheet{name:"Sheet1"}` (duplicate name) | `Error{code: SCRIPT_EXCEPTION}` (Excel semantics disallow duplicate sheet names) | Negative |
| C1.3 | Wb with sheets "Sheet1","Data" | `cell.setActiveSheet{name:"Data"}` then `cell.getActiveSheet{}` | returns `"Data"` | Positive |
| C1.4 | 1-sheet wb | `cell.setVisible{name:"Sheet1", visible:false}` on the *only* sheet | behavior depends on whether `worksheet.setHidden` itself enforces "can't hide the last visible sheet" -- not confirmed in `apiBuilder.js` (the check may live deeper in `AscCommonExcel`, not vendored/searched this pass); test result at the §6 build/deploy gate resolves this, not assumed here | Positive or Negative (unresolved -- verify at build/deploy gate) |
| C1.5 | Wb with sheet "Sheet1" | `cell.setName{oldName:"Sheet1", newName:"Renamed"}` | returns `null`; `cell.getSheets{}` no longer contains `"Sheet1"`, contains `"Renamed"` | Positive |

### C2. Cell/range read & write

Backing API confirmed: `ApiWorksheet.GetRange(Range1, Range2)` (`apiBuilder.js:8602`) resolves a range string on a given sheet; `ApiRange.SetValue(data)` (10161) has **no separate formula path** -- there is no `ApiRange.SetFormula` at all. Setting a cell's raw string value to something starting with `"="` is what makes it a formula (the same single setter Excel's own UI uses) -- corrected `cell.setValue`'s scope from separate `value`/`formula` fields down to one `value` field. `ApiRange.GetFormula()` (10241) returns `"= " + this.range.getFormula()` -- note the literal space after `=`, an unusual detail preserved here rather than assumed away.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C2.1 | 1-sheet wb | `cell.setValue{sheet:"Sheet1", range:"A1", value:42}` | returns `true`; `cell.getValue{sheet:"Sheet1", range:"A1"}` returns `42` | Positive |
| C2.2 | 1-sheet wb | `cell.setValue{sheet:"Sheet1", range:"A1", value:"=1+1"}` | returns `true`; `cell.getFormula{sheet:"Sheet1", range:"A1"}` returns `"= 1+1"` (note the space); `cell.getValue{...}` returns `2` post-recalc | Positive |
| C2.3 | 1-sheet wb | `cell.setValue{sheet:"Sheet1", range:"ZZ99999999", value:1}` (out-of-grid-bounds range) | `Error{code: SCRIPT_EXCEPTION}` -- `GetRange` throws when the range string doesn't resolve, not a gateway-schema-level rejection (range grammar isn't validated by a regex at the schema layer, deliberately, since Excel's range grammar is itself complex enough that re-validating it there would just duplicate `getRange2`'s own parsing) | Negative |
| C2.4 | 1-sheet wb | `cell.getValue{sheet:"NoSuchSheet", range:"A1"}` | `Error{code: SCRIPT_EXCEPTION}` (sheet not found) | Negative |

### C3. Number formats, merge, clear

Backing API confirmed: `ApiRange.SetNumberFormat(sFormat)`/`Merge(isAcross)`/`ClearContents()` (`apiBuilder.js:10828,10897,9759`) all return `null`/`undefined` on success (`SetNumberFormat`/`Merge` return `null` explicitly only on a protection failure, otherwise fall through with no return value). No "read formatted text" command is allowlisted yet (only `cell.getValue`, which returns the raw value, not the number-format-applied display string) -- C3.1's read-back is deferred to the §6 build/deploy gate rather than added as a new command speculatively.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C3.1 | A1 = 1234.5 | `cell.setNumberFormat{sheet:"Sheet1", range:"A1", format:"0.00"}` | returns `null`; formatted-text read-back deferred (no allowlisted command reads it yet) | Positive |
| C3.2 | A1:B2 unmerged | `cell.merge{sheet:"Sheet1", range:"A1:B2", across:false}` | returns `null` | Positive |
| C3.3 | A1 = "text" | `cell.clearContents{sheet:"Sheet1", range:"A1"}` | returns `null`; `cell.getValue{...}` returns empty/null | Positive |

### C4. Copy/paste, find/replace

Backing API confirmed: `ApiRange.Copy(destination)` (`apiBuilder.js:11338`) requires an actual `ApiRange` object as `destination`, not a string -- resolved via `ws.GetRange(scope.to)`. `ApiRange.Find(oSearchData)`/`Replace(oReplaceData)` (11616, 11764) are methods **on a range**, not a document/sheet-wide search -- `Find` returns **a single `ApiRange | null`** (the first match), not a list, so `cell.find`'s originally-planned "returns 2 matches" expectation doesn't correspond to any real capability of this method; corrected to reflect single-match semantics. Both operate over `ApiWorksheet.GetUsedRange()` (`apiBuilder.js:8524`) as the search scope, since no `range` scope field was in the original design and the real methods need one to call `.Find`/`.Replace` on. Result addresses read via `ApiRange.GetAddress()` (10043) rather than the unserializable `ApiRange` handle itself.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C4.1 | A1 = "src" | `cell.copy{sheet:"Sheet1", from:"A1", to:"B1"}` | returns `null`; B1 == `"src"` | Positive |
| C4.2 | A1:A3 contain "foo","bar","foo" | `cell.find{sheet:"Sheet1", text:"foo"}` | returns `"A1"` (the first match's address only -- `Find` has no "all matches" mode) | Positive |
| C4.3 | A1:A3 contain "foo","bar","foo" | `cell.replace{sheet:"Sheet1", find:"foo", replace:"baz"}` | returns the matched range's address or `null` if nothing matched; underlying `Replace` semantics (single vs. all occurrences) determined by `ReplaceAll`, defaulted to `true` in the command's script since the gateway command has no per-call granularity control in this design | Positive |

### C5. Font/fill/border/alignment formatting

Backing API confirmed: `ApiRange.SetFontName` (`apiBuilder.js:10513`) takes a plain string. `SetFillColor(oColor)` (10772) and `SetBorders(bordersIndex, lineStyle, oColor)` (from §C3's investigation, same file) both require a real `ApiColor` object, not a hex string -- built via `Api.CreateColorFromRGB(r,g,b)` (925), same r/g/b-from-hex decomposition already used for `word.setColor` (§B4). `SetBorders`'s `bordersIndex` switch (same method) has **no `"all"` case** -- only `DiagonalDown/DiagonalUp/Bottom/Left/Right/Top/InsideHorizontal/InsideVertical`; `edge:"all"` is handled by the command's script looping over the four outer edges, not a real single-call API mode. `SetAlignHorizontal` (10575) takes `'left'|'right'|'center'|'justify'` and returns `false` (not an exception) for an unrecognized value -- the command throws if that happens, keeping the gateway's own contract (schema-invalid inputs never reach here; this is a genuine unrecognized-but-schema-shaped case) consistent with everything else in this document.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C5.1 | A1 default font | `cell.setFontName{sheet:"Sheet1", range:"A1", font:"Calibri"}` | returns `null` | Positive |
| C5.2 | A1 default fill | `cell.setFillColor{sheet:"Sheet1", range:"A1", color:"#FFFF00"}` | returns `null` | Positive |
| C5.3 | A1 no borders | `cell.setBorders{sheet:"Sheet1", range:"A1", edge:"all", style:"thin", color:"#000000"}` | returns `null`; all 4 outer edges set via 4 internal `SetBorders` calls | Positive |
| C5.4 | A1 default align | `cell.setAlignHorizontal{sheet:"Sheet1", range:"A1", align:"center"}` | returns `null` | Positive |

### C6. Conditional formatting

Backing API confirmed: `ApiRange.GetFormatConditions()` (`apiBuilder.js:12827`) returns an `ApiFormatConditions` collection; `.Add*` methods (`AddColorScale(ColorScaleType)`, `AddDatabar()`, `AddIconSetCondition()`, lines 21119, 21229, 21299) each return the created rule object or `null` on failure, all JSON-unserializable -- commands return a boolean (`!!result`) instead, established pattern. `AddIconSetCondition()` takes **no parameters** -- the originally-planned `iconSet` scope field doesn't correspond to a constructor argument (icon-set type appears to be set via a property on the returned `ApiIconSetCondition`, not investigated further this pass since it's not needed to create a rule at all); dropped rather than guessed at.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C6.1 | A1:A10 with numeric values | `cell.addColorScale{sheet:"Sheet1", range:"A1:A10", scaleType:3}` | returns `true` | Positive |
| C6.2 | A1:A10 with numeric values | `cell.addDatabar{sheet:"Sheet1", range:"A1:A10"}` | returns `true` | Positive |
| C6.3 | A1:A10 with numeric values | `cell.addIconSetCondition{sheet:"Sheet1", range:"A1:A10"}` | returns `true`; the icon set itself is whatever `AddIconSetCondition()`'s own default is -- customizing it needs a follow-up investigation of `ApiIconSetCondition`'s own setters before adding scope fields for it | Positive |

### C7. Data validation and named ranges

Backing API confirmed: `ApiRange.GetValidation()` (`apiBuilder.js:12793`) returns an `ApiValidation`; `.Add(Type, AlertStyle, Operator, Formula1, Formula2)` (19898) takes the real internal enum strings (`FromXlValidationTypeTo`/`FromXlValidationOperatorTo`, 19653/19747) -- `"xlValidateWholeNumber"`/`"xlBetween"`, not the originally-planned `"whole"`/`"between"`; corrected the scope's `type`/`operator` fields to the real string values. `ApiWorksheet.AddDefName(sName, sRef, isHidden)` (8974) **returns `false`, not a thrown exception**, for an invalid name/ref (per its own doc comment) -- the command's script converts that `false` into a thrown error, keeping this gateway's own error contract (`SCRIPT_EXCEPTION`, not a silently-ignored `false`) consistent across every command, so C7.3's expected error code is unchanged even though the underlying method itself doesn't throw.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C7.1 | A1 no validation | `cell.addValidation{sheet:"Sheet1", range:"A1", type:"xlValidateWholeNumber", operator:"xlBetween", formula1:"1", formula2:"10"}` | returns `true`; whether `cell.setValue{...,value:20}` afterward is actually rejected is validation-enforcement behavior deferred to the §6 build/deploy gate (validation may be advisory, not enforced, at the model level) | Positive |
| C7.2 | 1-sheet wb | `cell.addDefName{name:"MyRange", refersTo:"Sheet1!$A$1:$A$5"}` | returns `true` | Positive |
| C7.3 | 1-sheet wb | `cell.addDefName{name:"1InvalidName", refersTo:"Sheet1!$A$1"}` (name starting with digit — invalid per Excel naming rules) | `Error{code: SCRIPT_EXCEPTION}` (the command throws on `AddDefName`'s `false` return, since the underlying method itself doesn't throw) | Negative |

### C8. AutoFilter

Backing API confirmed: `ApiAutoFilter.ApplyFilter()` (`apiBuilder.js:27379`) does **not** establish a new AutoFilter over a range at all -- per its own doc comment, it only "reevaluates which rows should be visible based on the active filters" for an AutoFilter that already exists, doing nothing otherwise. Establishing a new AutoFilter range is `ApiRange.SetAutoFilter(Field, ...)` (12216) called with no arguments, which creates one if none exists (and, confusingly, *deletes* the existing one if called again with no `Field` while one is already present -- a toggle, not idempotent). Corrected `cell.applyFilter` to call `SetAutoFilter()` on the resolved range, not the differently-named/differently-behaved `ApplyFilter`. `ApiAutoFilter.GetFilters()` returns `ApiFilter[]`, unserializable -- `cell.getFilters` returns `GetFilterMode()`'s boolean instead (whether *any* AutoFilter exists on the sheet at all), same established pattern.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C8.1 | A1:C10 tabular data with headers in row 1 | `cell.applyFilter{sheet:"Sheet1", range:"A1:C10"}` | returns `null`; `cell.getFilters{sheet:"Sheet1"}` returns `true` | Positive |
| C8.2 | 1-sheet wb, no filter applied at all | `cell.getFilters{sheet:"Sheet1"}` | returns `false`, not an error | Positive (boundary) |

### C9. PivotTable

Backing API confirmed: there is no `AddPivotTable`/`AddPivotDataField`-as-a-single-call shape at all -- the real workflow is three distinct steps, none of which match the original design's `sourceRange`-only addressing:
1. `Api.InsertPivotExistingWorksheet(dataRef, pivotRef, confirmation)` (`apiBuilder.js:7676`) creates the pivot table, taking real `ApiRange` objects (not strings) for both source and destination, returning an `ApiPivotTable`.
2. `ApiWorksheet.GetPivotByName(name)` (9412) is how a pivot table is *re*-resolved in a later, separate gateway call -- there's no addressing by source range. `ApiPivotTable.GetName()`/`SetName()` (16770/16782) exist, so the create command explicitly names the table so later commands can find it.
3. `ApiPivotTable.AddDataField(field)` (16192) returns an `ApiPivotDataField`, and **`ApiPivotField.SetFunction` (the originally-assumed target) is a hardcoded stub that always errors** ("This method can only be called on a data field... use ApiPivotTable.GetDataFields") -- the real setter is `ApiPivotDataField.SetFunction(func)` (17582), called either right after `AddDataField` or later via `ApiPivotTable.GetDataFields(field)` (16633) to re-resolve the same data field. `func` takes real enum strings (`"Sum"`, `"Average"`, `"Count"`, ... -- capitalized, not `"sum"`/`"average"`).

Commands redesigned around this real shape: `cell.addPivotTable` (create + name it), `cell.addPivotDataField` (add a data field to an already-created, named table), `cell.setPivotFieldFunction` (re-resolve and set a data field's aggregation).

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C9.1 | Source data range with a "Region" and "Sales" column in A1:B10 | `cell.addPivotTable{sourceSheet:"Sheet1", sourceRange:"A1:B10", pivotSheet:"Sheet1", pivotRange:"D1", name:"MyPivot"}` | returns `true` | Positive |
| C9.2 | Pivot table "MyPivot" created | `cell.addPivotDataField{sheet:"Sheet1", pivotName:"MyPivot", field:"Sales", func:"Sum"}` | returns `true` | Positive |
| C9.3 | Pivot table "MyPivot" has a "Sales" data field | `cell.setPivotFieldFunction{sheet:"Sheet1", pivotName:"MyPivot", field:"Sales", func:"Average"}` | returns `true` | Positive |
| C9.4 | Pivot table "MyPivot", source has no "NoSuchColumn" | `cell.addPivotDataField{sheet:"Sheet1", pivotName:"MyPivot", field:"NoSuchColumn", func:"Sum"}` | `Error{code: SCRIPT_EXCEPTION}` (`AddDataField` calls `private_MakeError` and returns `null` for an unknown field -- converted to a thrown error, same pattern as elsewhere) | Negative |

### C10. Freeze panes

Backing API confirmed: `ApiWorksheet.GetFreezePanes()` (`apiBuilder.js:9474`) + `ApiFreezePanes.FreezeAt(frozenRange)` (15780) -- takes a range resolved on the *active* worksheet if given as a string (`api.GetRange`, ambiguous relative to a `sheet` scope field not necessarily active), so the command resolves the range explicitly via `ws.GetRange(range)` first and passes the real `ApiRange` object instead, avoiding relying on the string-overload's own sheet-context guess.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C10.1 | 1-sheet wb, no freeze | `cell.freezeAt{sheet:"Sheet1", range:"B2"}` | returns `null` | Positive |
| C10.2 | Frozen at B2 | `cell.freezeAt{sheet:"Sheet1", range:"A1"}` (freeze at origin = effectively unfreeze, per `FreezeAt`'s own bbox-based logic) | returns `null` | Positive (boundary) |

### C11. Insert images/shapes/OLE objects

Backing API confirmed: `ApiWorksheet.AddImage`/`AddOleObject` (`apiBuilder.js:9167,9228`) place objects by column/row + EMU offset, not a `range`/`path` -- `sImageSrc` is a URL or base64 data URI (same as `word.createImage`, §B9), not a local file path. `AddShape(sType, nWidth, nHeight, oFill, oStroke, ...)` (9146) requires real `ApiFill`/`ApiStroke` objects (`oFill.UniFill`, `oStroke.Ln`) -- their constructors (`Api.CreateSolidFill`/`CreateNoFill`/`CreateStroke` or similar) are not defined in `sdkjs/cell/apiBuilder.js` itself (only referenced via `Asc.editor.CreateNoFill()` at line 9198, suggesting a shared cross-editor factory not yet located in this pass). **`cell.addShape` is deferred, not guessed** -- same discipline as `word.addCheckBoxForm` (§B12) -- until the Fill/Stroke factory is confirmed.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C11.1 | 1-sheet wb, valid base64-encoded PNG fixture | `cell.addImage{sheet:"Sheet1", imageSrc:"data:image/png;base64,<fixture>", width:914400, height:914400, fromCol:0, colOffset:0, fromRow:0, rowOffset:0}` | returns `true` | Positive |
| C11.2 | *(deferred -- see note above)* | `cell.addShape{...}` | not implemented in this pass | Deferred |
| C11.3 | 1-sheet wb, fixture base64 OLE payload | `cell.addOleObject{sheet:"Sheet1", imageSrc:"data:image/png;base64,<preview>", width:914400, height:914400, data:"<fixture-data>", appId:"x-office/binary", fromCol:0, colOffset:0, fromRow:0, rowOffset:0}` | returns `true` | Positive |

### C12. Comments with replies

Backing API confirmed: `ApiRange.AddComment(sText, sAuthor)` (`apiBuilder.js:10969`) returns an `ApiComment | null`. `ApiComment` has no public row/col accessor to re-resolve "the comment on range X" from a *separate*, later gateway call -- but it does have `GetId()` (13921, returns a string). `cell.addReply`/`cell.setSolved` therefore address a comment by the id `cell.addComment` returns, resolved via `ws.GetComments().find(c => c.GetId() === commentId)`, rather than by range -- the range-based addressing in the original design doesn't correspond to any real lookup capability.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C12.1 | A1 no comment | `cell.addComment{sheet:"Sheet1", range:"A1", text:"check this", author:"peter"}` | returns the new comment's id (a non-empty string) | Positive |
| C12.2 | A1 has 1 comment with id from C12.1 | `cell.addReply{sheet:"Sheet1", commentId:"<id>", text:"done", author:"jane"}` | returns `null`; the comment's reply count increases by 1 | Positive |
| C12.3 | A1 has a comment with id from C12.1 | `cell.setSolved{sheet:"Sheet1", commentId:"<id>", solved:true}` | returns `null` | Positive |

### C13. Insert/delete rows and columns

Backing API confirmed: `ApiWorksheet.GetRangeByNumber(nRow, nCol)` (`apiBuilder.js:8642`) resolves 0-based grid coordinates directly (`worksheet.getCell3`), matching this document's established row/col index convention -- used to anchor `GetEntireRow()`/`GetEntireColumn()` (12753, 12775) before `Insert(shift)`/`Delete(shift)` (11280, 11241), which take a shift direction string and return nothing.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C13.1 | A1="x", A2="y" | `cell.insertEntireRow{sheet:"Sheet1", rowIndex:1}` | returns `null`; new blank row at index 1; former A2("y") is now A3 | Positive |
| C13.2 | A1="x", B1="y" | `cell.deleteEntireColumn{sheet:"Sheet1", colIndex:0}` | returns `null`; column A removed; former B1("y") is now A1 | Positive |
| C13.3 | 1-sheet wb | `cell.insertEntireRow{sheet:"Sheet1", rowIndex:-1}` | `Error{code: SCHEMA_INVALID}` (schema `minimum:0`) | Negative |

### C14. Recalculate formulas

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C14.1 | A1=2, B1="=A1*2" (formula not yet recalculated after A1 was changed programmatically) | `cell.recalculateAllFormulas{}` | B1's value reads `4` | Positive |
| C14.2 | Workbook with a formula referencing a deleted/invalid range | `cell.recalculateAllFormulas{}` | call succeeds without throwing; the affected cell shows an in-document `#REF!`-style error value, not a gateway-level error | Positive (boundary) |

### C15. Create charts and edit data series

Backing API confirmed: `ApiWorksheet.GetAllCharts()` (`apiBuilder.js:9359`) is the addressing mechanism -- `chartIndex` indexes into it, matching this document's established index-based pattern already, no redesign needed (unlike §C9/§C12's name/id-based fixes, `ApiChart` has no `GetName`/`SetName` at all, so index-into-`GetAllCharts()` is in fact the *only* real addressing option). `ApiChart.AddSeria(sNameRange, sValuesRange, sXValuesRange)` (13641) and `SetSeriaName(sNameRange, nSeria)` (13608) both take **range strings** (or plain text for the name) rather than a single `range`/`name` scalar -- `cell.addSeria`'s `range` scope field maps to `sValuesRange` (with name left blank/auto), and `cell.setSeriaName`'s `name` field is passed as `sNameRange`, which the underlying method accepts as either a formula range or literal text per its own doc comment. Chart *creation* (`ApiWorksheet.AddChart`, 9098) is out of scope for this family per the original design (fixtures assume a pre-existing chart) -- not added speculatively.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C15.1 | Sheet with 1 chart, 1 series | `cell.addSeria{sheet:"Sheet1", chartIndex:0, valuesRange:"Sheet1!B1:B10"}` | returns `null`; chart now has 2 series | Positive |
| C15.2 | Sheet with 1 chart, 1 series named "Old" | `cell.setSeriaName{sheet:"Sheet1", chartIndex:0, seriaIndex:0, name:"Revenue"}` | returns `true` | Positive |

### C16. Read SmartArt object type

Backing API confirmed: `ApiSmartArt` (`apiBuilder.js:13294`) is one variant of the generic `Drawing` typedef (313: `ApiShape | ApiImage | ApiOleObject | ApiChart | ApiGroup | ApiSmartArt`) -- there is no SmartArt-specific collection accessor; `index` addresses into `ApiWorksheet.GetAllDrawings()` (9271), the generic mixed-type collection, not a SmartArt-only one.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| C16.1 | Sheet with 1 SmartArt object of a known class at drawing index 0 | `cell.getSmartArtClassType{sheet:"Sheet1", index:0}` | returns the expected type string, matching the fixture | Positive |
| C16.2 | Sheet with no drawings at all | `cell.getSmartArtClassType{sheet:"Sheet1", index:0}` | `Error{code: SCRIPT_EXCEPTION}` (accessing `.GetClassType()` on `undefined` throws a plain JS `TypeError`, propagated the same as any other script exception) | Negative |

---

## D. Slide (Presentation)

Fixture convention: "3-slide deck" = presentation with 3 slides, slide 0 has 1 text box.

### D1. Slide management

Backing API confirmed: `ApiPresentation.AddSlide(oSlide, nIndex)` (`sdkjs/slide/apiBuilder.js:1365`) needs an actual `ApiSlide` built via `Api.CreateSlide()` (805), not a bare index -- an out-of-range `nIndex` is silently treated as "append at end", not an error. `RemoveSlides(nStart, nCount)` (1564) takes a **contiguous start+count range**, not an arbitrary `indices` array as originally planned -- and **returns `false` rather than throwing** for an out-of-range `nStart` (the whole removal block is skipped silently); the command's script converts that `false` into a thrown error, same pattern as elsewhere in this document. `ApiSlide.Duplicate(nPos)`/`MoveTo(nPos)` (3853, 3872) are called on a resolved `ApiSlide` (via `ApiPresentation.GetSlideByIndex`, 1324), not `ApiPresentation` directly.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D1.1 | 3-slide deck | `slide.addSlide{index:1}` | returns `null`; deck now has 4 slides, new slide at position 1 | Positive |
| D1.2 | 3-slide deck | `slide.removeSlides{start:1, count:1}` | returns `true`; deck now has 2 slides; former slide 2 is now slide 1 | Positive |
| D1.3 | 3-slide deck | `slide.duplicate{index:0}` | returns `true`; deck now has 4 slides; slide at index 1 has content matching original slide 0 | Positive |
| D1.4 | 3-slide deck | `slide.moveTo{index:0, newIndex:2}` | returns `true`; slide originally at 0 is now at 2; others shift accordingly | Positive |
| D1.5 | 3-slide deck | `slide.removeSlides{start:99, count:1}` (out of range) | `Error{code: SCRIPT_EXCEPTION}` (converted from `RemoveSlides`'s own `false` return, since the underlying method itself doesn't throw) | Negative |
| D1.6 | 1-slide deck (only slide) | `slide.removeSlides{start:0, count:1}` | returns `true` -- `RemoveSlides`'s own bounds check (`nStart < GetSlidesCount()`) has no special guard against reaching 0 slides, confirmed in source; whether a 0-slide presentation is a stable runtime state isn't verifiable from source alone, deferred to the §6 build/deploy gate | Positive |

### D2. Enumerate slide content

Backing API confirmed: `ApiSlide.GetAllShapes/GetAllImages/GetAllTables/GetAllCharts` (`sdkjs/slide/apiBuilder.js:4140,4155,4197,4169`) match the plan exactly, each returning `Api*[]` -- not JSON-serializable, same established pattern as `word.getAllTables` (§B2) -- so these return index arrays (`0..length-1`) instead. `index` addresses the slide via `ApiPresentation.GetSlideByIndex` (§D1's resolveSlide), not the slide's content directly.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D2.1 | Slide with 2 shapes, 1 image, 1 table, 1 chart | `slide.getAllShapes{index:0}` | returns `[0,1]` | Positive |
| D2.2 | same fixture | `slide.getAllImages{index:0}` | returns `[0]` | Positive |
| D2.3 | same fixture | `slide.getAllTables{index:0}` | returns `[0]` | Positive |
| D2.4 | same fixture | `slide.getAllCharts{index:0}` | returns `[0]` | Positive |
| D2.5 | blank slide | `slide.getAllShapes{index:2}` (empty slide) | returns empty array, not an error | Positive (boundary) |

### D3. Apply layouts, masters, themes (theme application deferred)

Backing API confirmed: layouts/masters/themes have no id-string addressing at all -- `ApiSlide.GetLayout()`/`ApplyLayout(oLayout)` (`sdkjs/slide/apiBuilder.js:4092,3800`) work with real `ApiLayout` objects, `ApiPresentation.AddMaster(nPos, oApiMaster)` (1522) needs a real `ApiMaster` (from `Api.CreateMaster(oTheme)`, 553), and `ApplyTheme(oApiTheme)` (1545) needs a real `ApiTheme`. `Api.CreateTheme(sName, oMaster, oClrScheme, oFormatScheme, oFontScheme)` (640) requires **three further factory-built objects** (`ApiThemeColorScheme`/`ApiThemeFormatScheme`/`ApiThemeFontScheme`) whose own constructors weren't confirmed in this pass -- **`slide.applyTheme` is deferred, not guessed**, same discipline as `word.addCheckBoxForm` (§B12) and `cell.addShape` (§C11). `slide.applyLayout` is redesigned around borrowing an already-resolved layout from another slide (`GetLayout()` → `ApplyLayout()`), which only needs methods already confirmed, rather than a `layoutId` string that doesn't correspond to any real lookup. `slide.addMaster` uses `Api.CreateMaster()` with no theme argument, relying on its own documented fallback (defaults to the presentation's existing master-0 theme, or the current theme if none) rather than us constructing one.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D3.1 | slide with default layout | `slide.getLayout{index:0}` | returns `true` (has a layout) | Positive |
| D3.2 | Two slides with different layouts | `slide.applyLayout{index:0, fromIndex:1}` | returns `true`; slide 0 now uses slide 1's layout | Positive |
| D3.3 | deck with 1 master | `slide.addMaster{position:1}` | returns `true`; deck's master count increases by 1 | Positive |
| D3.4 | *(deferred -- see note above)* | `slide.applyTheme{...}` | not implemented in this pass | Deferred |

### D4. Set transitions (background deferred)

Backing API confirmed: `ApiSlide.SetBackground(oApiFill)` (`sdkjs/slide/apiBuilder.js:3723`) needs a real `ApiFill` object -- no `Api.CreateSolidFill`-style factory was found in this file (only `Api.CreateNoFill`, confirmed, and `Api.CreateStroke`), so **`slide.setBackground` is deferred, not guessed**, same discipline as `word.addCheckBoxForm` (§B12), `cell.addShape` (§C11), `slide.applyTheme` (§D3). `ApiSlide.SetSlideShowTransition(transition)` (4389) needs a real `ApiSlideShowTransition` from `Api.CreateSlideShowTransition()` (1075, no-arg, confirmed) configured via `SetEntryEffect(entryEffectName)`/`SetDuration(duration)` (4848, 4902) -- the field is `entryEffect`, not `type`, and `SetEntryEffect` returns `false` (not a throw) for an unsupported name.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D4.1 | *(deferred -- see note above)* | `slide.setBackground{...}` | not implemented in this pass | Deferred |
| D4.2 | slide, no transition | `slide.setTransition{index:0, entryEffect:"effectFade", duration:500}` | returns `true` | Positive |

### D5. Insert shapes/text boxes with positioning

Backing API confirmed: `Api.CreateShape(sType, nWidth, nHeight, oFill, oStroke)` (`sdkjs/slide/apiBuilder.js:870`) has real internal defaults for `oFill`/`oStroke` (falls back to `Api.CreateNoFill()`/`Api.CreateStroke(0, Api.CreateNoFill())` when omitted) -- unlike Cell's `AddShape` (§C11), this one doesn't need us to construct fill/stroke objects, so it's fully implementable. `CreateShape` doesn't take a position -- the shape is attached to a slide via `ApiSlide.AddObject(oDrawing)` (3621) and positioned separately via `ApiDrawing.SetPosition(nPosX, nPosY)` (6100), so `slide.createShape`'s `x`/`y` map to a follow-up `SetPosition` call in the same command, not `CreateShape` itself. `SetSize`/`SetRotation` (6079, 6511) confirmed as planned.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D5.1 | blank slide | `slide.createShape{index:0, type:"rect", x:10, y:10, width:100, height:50}` | returns `true` | Positive |
| D5.2 | shape created | `slide.setPosition{index:0, shapeIndex:0, x:200, y:200}` | returns `null` | Positive |
| D5.3 | shape created | `slide.setRotation{index:0, shapeIndex:0, degrees:45}` | returns `true` | Positive |
| D5.4 | shape created | `slide.setSize{index:0, shapeIndex:0, width:-10, height:50}` (negative width) | `Error{code: SCHEMA_INVALID}` (schema `minimum:0`) | Negative |

### D6. Text formatting

`ApiRun.SetBold`/`SetFontFamily` are shared classes with Word (confirmed absent from `sdkjs/slide/apiBuilder.js` itself, so they must come from a common file included by all three editors, per the plan's own note) -- these test cases exist to prove the *slide-side target resolution* works, not to re-derive formatting semantics already covered in §B4. Target resolution: `ApiShape.GetContent()` (`sdkjs/slide/apiBuilder.js:6975`, `GetDocContent` is its deprecated alias) returns an `ApiDocumentContent`, navigated the same `GetElement(paraIndex).GetElement(runIndex)` chain as Word (§B3/§B4) -- the originally-planned scope was missing `paraIndex` (a text box's run still lives inside a paragraph), added below.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D6.1 | slide 0 has 1 text box with 1 paragraph, 1 run | `slide.setBold{index:0, shapeIndex:0, paraIndex:0, runIndex:0, bold:true}` | returns `null` | Positive |
| D6.2 | same fixture | `slide.setFontFamily{index:0, shapeIndex:0, paraIndex:0, runIndex:0, font:"Georgia"}` | returns `null` | Positive |

### D7. Insert images

Backing API confirmed: `Api.CreateImage(sImageSrc, nWidth, nHeight)` (`sdkjs/slide/apiBuilder.js:825`) matches the Word/Cell precedent exactly -- `sImageSrc` is a URL or base64 data URI, not a local file path (correcting the originally-planned `path`, same fix as `word.createImage` §B9). No position param -- attached via `ApiSlide.AddObject` (§D5) then positioned via `ApiDrawing.SetPosition` (§D5), same two-step pattern as `slide.createShape`.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D7.1 | blank slide, valid base64-encoded PNG fixture | `slide.createImage{index:0, imageSrc:"data:image/png;base64,<fixture>", x:0, y:0, width:914400, height:914400}` | returns `true` | Positive |

### D8. Table editing (creation deferred)

Backing API confirmed: `Api.CreateTable(nCols, nRows)` (`sdkjs/slide/apiBuilder.js:947`) places the table on **whatever slide `private_GetCurrentSlide()` currently resolves to** (`ApiPresentation.GetCurSlideIndex()`) -- there is no `ApiPresentation.SetCurSlideIndex`-style public setter to target an arbitrary slide by index first, unlike `AddSlide`'s own internal `CurPage` manipulation. Reliably creating a table on a specific slide via automation therefore isn't possible with the confirmed API surface -- **`slide.createTable` is deferred, not guessed**, same discipline as `slide.applyTheme`/`slide.setBackground`. `ApiTable.AddRow`/`MergeCells` (7412, 7314) operate on an **already-existing** table, addressed via `slide.GetAllTables()[tableIndex]` (§D2's established index space) -- fully implementable regardless of the creation gap. Cell resolution for `MergeCells` uses `ApiTable.GetRow(r).GetCell(c)` (7295, `ApiTableRow.GetCell`, 7614) -- slide's `ApiTable` has **no** `GetCell(row, col)` shortcut the way Word's does.

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D8.1 | *(deferred -- see note above)* | `slide.createTable{...}` | not implemented in this pass | Deferred |
| D8.2 | slide with 1 table, 2x2 | `slide.addRow{index:0, tableIndex:0}` | returns `true`; table now 3 rows | Positive |
| D8.3 | slide with 1 table, 2x2 | `slide.mergeCells{index:0, tableIndex:0, fromRow:0, fromCol:0, toRow:0, toCol:1}` | resulting merged cell spans 2 columns | Positive |

### D9. Speaker notes

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D9.1 | slide 0, no notes | `slide.addNotesText{index:0, text:"Remember to mention Q3"}` | `slide.getNotesPage{index:0}` text contains `"Remember to mention Q3"` | Positive |
| D9.2 | slide 0, notes already set | `slide.addNotesText{index:0, text:"Second note"}` (appending vs. replacing — pin behavior) | notes content reflects whichever is the defined behavior (append or replace); test locks it in | Positive |

### D10. Comments

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D10.1 | slide 0, no comments | `slide.addComment{index:0, text:"fix typo", author:"peter"}` | `presentation.getAllComments{}` length 1, matches text/author, references slide 0 | Positive |
| D10.2 | deck with no comments anywhere | `presentation.getAllComments{}` | returns empty array, not an error | Positive (boundary) |

### D11. Document properties

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| D11.1 | fresh deck | `presentation.getDocumentInfo{}` | returns a well-formed info object (title/author/etc, even if defaults) | Positive |
| D11.2 | fresh deck, custom prop set via fixture | `presentation.getCustomProperties{}` | returns the fixture's custom properties | Positive |

---

## E. PDF

Fixture convention: "1-page PDF" = a single-page PDF with one text form field "Name" and no annotations.

### E1. Form field read/write

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| E1.1 | 1-page PDF, field "Name" empty | `pdf.getAllFields{}` | returns 1 field, key `"Name"`, type text | Positive |
| E1.2 | field "Name" empty | `pdf.setFieldValue{key:"Name", value:"Alice"}` | `pdf.getAllFields{}` shows field "Name" value `"Alice"` | Positive |
| E1.3 | fixture with 1 checkbox field "Agree", unchecked | `pdf.setFieldValue{key:"Agree", value:true}` | field reads back checked | Positive |
| E1.4 | 1-page PDF | `pdf.setFieldValue{key:"DoesNotExist", value:"x"}` | `Error{code: SCRIPT_EXCEPTION}` (no such field) | Negative |
| E1.5 | fixture with 1 combobox field "Country" with options ["US","UK"] | `pdf.setFieldValue{key:"Country", value:"FR"}` (not in the option list) | either rejected (`Error{code: SCRIPT_EXCEPTION}`) or accepted as free text depending on the underlying combobox's `editable` flag — pin behavior at implementation | Positive or Negative (decide) |

### E2. Annotations

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| E2.1 | 1-page PDF, no annotations, page has visible text | `pdf.addHighlight{page:0, rect:[10,10,100,20]}` | `pdf.getAllAnnots{page:0}` length 1, type highlight, matching rect | Positive |
| E2.2 | same page | `pdf.addUnderline{page:0, rect:[10,10,100,20]}` | annotation count +1, type underline | Positive |
| E2.3 | same page | `pdf.addStrikeout{page:0, rect:[10,10,100,20]}` | annotation count +1, type strikeout | Positive |
| E2.4 | same page | `pdf.addFreeText{page:0, rect:[10,10,150,40], text:"Note"}` | annotation count +1, type free-text, text matches | Positive |
| E2.5 | same page | `pdf.addInk{page:0, points:[[10,10],[20,20],[30,10]]}` | annotation count +1, type ink | Positive |
| E2.6 | same page | `pdf.addStamp{page:0, rect:[10,10,50,50], stampType:"Approved"}` | annotation count +1, type stamp | Positive |
| E2.7 | 1-page PDF | `pdf.addHighlight{page:5, rect:[10,10,100,20]}` (page out of range for a 1-page doc) | `Error{code: SCRIPT_EXCEPTION}` | Negative |
| E2.8 | same page | `pdf.addHighlight{page:0, rect:[-5,-5,-1,-1]}` (degenerate/negative rect) | `Error{code: SCHEMA_INVALID}` (schema constrains rect coordinates to be non-negative and `x2>x1`, `y2>y1`) | Negative |

### E3. Text search/extraction

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| E3.1 | page contains "Invoice Total: $500" | `pdf.search{page:0, text:"Total"}` | returns 1 match with correct location | Positive |
| E3.2 | page contains "Invoice Total: $500" | `pdf.getSelectedText{page:0, rect:[<bounds around "Total">]}` | returns `"Total"` | Positive |
| E3.3 | page with no matching text | `pdf.search{page:0, text:"zzz-not-present"}` | returns empty array, not an error | Positive (boundary) |
| E3.4 | scanned/image-only page (no text layer) | `pdf.recognizeContent{page:0}` | returns recognized text (OCR) matching the fixture's known ground truth, within reasonable tolerance | Positive |

### E4. Redaction

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| E4.1 | page contains "SSN: 123-45-6789" | `pdf.applyRedact{page:0, rect:[<bounds around the SSN>]}` | subsequent `pdf.search{page:0, text:"123-45-6789"}` returns 0 matches; extracted text no longer contains it | Positive |
| E4.2 | page contains "SSN: 123-45-6789" and "SSN: 987-65-4321" | `pdf.searchAndRedact{text:"SSN:"}` (pattern-based redaction across whole doc) | both SSN lines are redacted; a benign unrelated "SSN" false-positive-free page is unaffected | Positive |
| E4.3 | page with no matching text | `pdf.searchAndRedact{text:"NOT-PRESENT"}` | succeeds as a no-op, 0 redactions applied, not an error | Positive (boundary) |

### E5. Page operations

| ID | Setup | Input | Expected | Type |
|---|---|---|---|---|
| E5.1 | 1-page PDF | `pdf.addPage{index:1}` | document now has 2 pages | Positive |
| E5.2 | 2-page PDF | `pdf.removePage{index:0}` | document now has 1 page; remaining page is what was previously page 1 | Positive |
| E5.3 | 1-page PDF (only page) | `pdf.removePage{index:0}` | either rejected (`Error{code: SCRIPT_EXCEPTION}`, a PDF can't have 0 pages) or produces an empty/invalid document — pin behavior, this is a meaningful edge case to lock down before shipping | Negative (expected) |

---

## F. Cross-editor regression suite

Not new test cases — this is the **execution instruction** referenced by [cdp-gateway-cli-plan.md](cdp-gateway-cli-plan.md) §6 step 4: after each editor's command family is fully implemented and its own section above passes, re-run *every* previously-passing section in this document (§B for Cell's gate, §B+§C for Slide's gate, §B+§C+§D for PDF's gate) against the same freshly built binary, unmodified. A regression is any test case that previously passed and now doesn't — no re-interpretation of "expected" is allowed at that point without a deliberate, called-out design change.
