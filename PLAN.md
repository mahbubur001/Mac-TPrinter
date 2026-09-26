# TPrinter — Project Plan

A native macOS app that connects to a **Rongta RP310** thermal label printer over
Bluetooth and prints labels (text, barcodes, QR codes, images, icons).

## Facts established

| Item | Value |
|---|---|
| Printer | Rongta RP310, dual-mode: Classic `RP310-D157` + BLE `RP310-D157-BLE` |
| Transport | Classic Bluetooth RFCOMM channel 1 via IOBluetooth (primary, verified), BLE via CoreBluetooth (fallback). `/dev/cu.*` does NOT work |
| Label stock | 30 × 15 mm, 2 mm gap |
| Command language | TSPL (TSC-compatible label language); ESC/POS as fallback |
| Resolution | 203 dpi = 8 dots/mm (verify against the manual) |
| Toolchain | Swift 6.4 Command Line Tools, **no Xcode** → Swift Package + bundling script, built against the macOS 26 SDK (see CLAUDE.md) |
| macOS | 26.x (app targets macOS 14+) |

## Architecture

```
SwiftUI views ──► LabelDocument (model)
      │                 │
      │                 ├─► LabelRenderView ──► LabelRasterizer ──► 1-bit bitmap
      │                 │                                             │
      │                 └─► TSPLCommandBuilder ◄──────────────────────┘
      │                              │ (Data)
      └──► PrinterBluetoothManager ◄─┘  scan / connect / chunked BLE writes
```

Two print methods:
1. **Image (default, WYSIWYG)** — the label preview is rendered to a 1-bit image
   and sent with TSPL `BITMAP`. Any font, exactly what you see.
2. **Native TSPL** — `TEXT` / `BARCODE` / `QRCODE` commands; smaller payload,
   printer's built-in fonts.

## Phases

### Phase 1 — Scaffolding ✅
- [x] `TPrinter/` Swift package, folder layout, `CLAUDE.md`, `PLAN.md`
- [x] `Info.plist` with Bluetooth usage description (embedded into binary + bundle)
- [x] `scripts/build-app.sh` → builds `TPrinter.app` (ad-hoc signed)
- [x] Unit tests: TSPL builder, rasterizer, layout fit, test job, alignment (98 passing; run via `scripts/test.sh`)

### Phase 2 — Bluetooth connection ✅ (code) / ⏳ (verify on device)
- [x] Scan for peripherals, show names + RSSI, filter to printers
- [x] Connect, discover all services/characteristics
- [x] Auto-select writable characteristic (known Rongta/ISSC/FFxx UUIDs first)
- [x] Chunked writes honoring `maximumWriteValueLength` and flow control
- [x] Remember last printer, reconnect on launch
- [x] ~~`/dev/cu.RP310-D157` serial port~~: writes silently never reach the printer, removed
- [x] Classic Bluetooth RFCOMM transport (IOBluetooth): TSPL text + BITMAP verified printing (2026-09-24)
- [x] Printing from the app itself over RFCOMM verified
- [x] Fixed: ad-hoc signing lost the Bluetooth permission on every rebuild → stable self-signed cert
- [x] Console mirrored to `~/Library/Logs/TPrinter.log`
- [ ] Verify against the real RP310 and record the actual service/characteristic UUIDs in `CLAUDE.md`

### Phase 3 — Printing ✅ (code) / ⏳ (verify on device)
- [x] TSPL command builder (SIZE, GAP, DENSITY, SPEED, DIRECTION, CLS, TEXT, BARCODE, QRCODE, BITMAP, PRINT)
- [x] "Test print" button
- [x] Raw command console (send any TSPL / hex for debugging)
- [x] BITMAP polarity confirmed: 0 = black (solid box test printed black)
- [x] Test Print job fixed: ASCII-only date, fits 30 × 15 mm
- [x] Full image label prints upright (DIRECTION 1)
- [x] Print starts ~3 mm early: SHIFT/OFFSET/GAPDETECT/GAP size/DIRECTION don't help; SIZE lead-in works but wastes a blank label per print
- [x] GAP offset (`GAP 2 mm, 1–4 mm`) tested: no effect
- [x] ~~2.5 mm blank lead-in (SIZE 17.5)~~: aligned but fed blank labels after prints
- [x] **Fix: `SET TEAR OFF` + real SIZE** — aligned, no blank labels (2 jobs on one channel, 2026-09-24)
- [x] Hello Label at 2.5 mm prints matching the preview (confirmed 2026-09-24)
- [ ] Tune default density / speed / chunk size
- [ ] Check the 1-dot-wide barcode bars scan reliably on 30 × 15 mm labels

### Phase 4 — Label designer ✅ (MVP)
- [x] Label size, gap, copies settings
- [x] Elements: text, Code-128 barcode, QR code; position in mm
- [x] Live preview at true print resolution
- [x] Default layout fitted to 30 × 15 mm (tests check fit + no overlap)
- [x] Drag elements on the preview (0.5 mm snap, ⌥ = free move, kept on the label, live x/y readout)
- [x] Arrow-key nudging on the preview (0.5 mm, ⇧ 5 mm, ⌥ 1 dot)
- [x] Resize handles: 8 (corners + sides), continuous (0.1 mm, corners follow the diagonal), opposite side fixed;
  text sides = box width (shrink to fit), barcode sides = bar width / height; ⌥ free; one undo step.
  Moving a selected element still works (handles only capture their own area)
- [x] Double-click to edit text / barcode / QR content in place (Return saves, Esc cancels)
- [x] Rename layers: double-click in Layers or Rename… in the right-click menu; empty = automatic name; saved in templates
- [x] Right-click menu on elements (canvas + layers): Duplicate, Arrange, Align on Label, Replace Image, Shrink to Fit, Delete
- [x] Undo / Redo for all label edits (named steps, quick repeats coalesce, "Edited" tracks the saved state)
- [x] Image element: file picker or drop on canvas, photo (dither) / line-art (threshold), darkness, width; stored in template
- [x] Icon element: curated SF Symbol picker + search any symbol name
- [x] Text "Shrink to fit": font shrinks (never grows) so the widest line fits a max width; per CSV row in batches; native TSPL picks a smaller printer font
- [x] Modern redesign: label-on-roll canvas with zoom, printer status LED card, layers list (reorder, duplicate, delete), contextual inspector, Insert toolbar, log drawer
- [x] Fixed: light-coloured logos (e.g. gold on white) previewed/printed blank → auto-levels (darkest tone = black),
  margin trim on import, line-art detection by paper share, line-art darkness 0.65
  - Margins are also trimmed when drawing (fixes logos stored before the fix); white image dots blend with the preview paper
- [ ] Confirm an image and an icon print from TPrinter itself (earlier "looks good" print isn't in the app log)
- [x] Save / open label templates (`.tprlabel` JSON, versioned, tolerant of missing fields)
  - File menu: New Label ⌘N, Open Template… ⌘O, Open Recent, Save Template ⌘S, Save Template As… ⇧⌘S
  - Unsaved-changes prompt on New/Open; window title shows name + "Edited"
  - Double-click `.tprlabel` in Finder opens it (verified); working copy autosaved across relaunches
  - Sample: `TPrinter/Templates/Hello 30x15.tprlabel`

- [x] Dashboard start page (shown at launch): continue current label, new label at preset sizes drawn to scale,
  recent templates with thumbnails, printer status/choice, Open Template, Batch Print; toolbar button + ⇧⌘D
  - Redesign: hero = current label on its roll + Continue / Print; printer pill; stock sizes as offcuts with hover lift;
    recent cards with "Edited …" + context menu (Show in Finder, Remove from Recents)

### Phase 4b — App redesign ✅ (preview approved 2026-09-25)
- [x] Hidden title bar; home header (app icon + name, notifications bell, settings)
- [x] Floating bottom tabs: Templates, Dashboard, Batch, History, Settings (⌘1–5)
- [x] Dashboard: printer panel (status, connection, media loaded, resolution, printed today, search & connect, test print), 8 quick actions, recent work
- [x] Media: library with categories + filter, create/edit/delete, separation (gap / black mark / continuous), labels across, material, default darkness/speed
- [x] New label flow: choose media → arrangement (grid, label size, margins, spacing, live preview) → editor
- [x] Full-page editor: floating header (back, name, media, printer, Save, Print, more), tools, layers, inspector, log
- [x] History (persisted, filters, Reprint) + notifications (print results, printer connect/disconnect)
- [x] Settings: appearance, printers, media, default print method, alignment/calibration, templates folder, about
- [x] Templates: Import (panel or drop, unique names), Duplicate, Rename, Export (.tprlabel or 4× PNG), Move to Trash;
  redesigned with search, category chips with counts, sort, grid/list, hover Print / ⋯
- [x] History redesign: totals (today / 7 days / all time / problems), search, filter counts, grouped by day,
  as-printed thumbnails, Reprint / Open in Editor / Export Image / Remove
- [x] Batch redesign: steps (template + field check, CSV drop zone, range/copies/print), live preview with row
  navigator, CSV data table with per-row Printed / Printing / Waiting / Skipped; batch state survives tab switches
- [x] Tab bar order: Templates, Batch, Dashboard (centre), History, Settings
- [x] Fixed: a duplicated template outside the templates folder wasn't listed → duplicates join recents
- [x] Settings redesign: searchable sidebar with icon tiles, section headers, grouped rows; appearance tiles;
  editor panel defaults; notification switches per topic (prints / printer / templates); media list beside editor
- [ ] Verify a multi-column arrangement on multi-across media (current roll is single-column)

### Phase 4c — Editor redesign ✅ (preview approved 2026-09-25)
- [x] Docked layout (toolbar · tool rail · layers · canvas + status strip · inspector), no overlapping panels
- [x] Rulers, safe-margin guide, snap guides, off-label warnings with Shrink / Wrap / Fit on Label
- [x] Every tool per element: text (font family, weight, italic/underline/strike, case, align, line/letter spacing,
  wrap/shrink box, white-on-black, outline), barcode (number above/below/size, quiet zone), QR (Wi-Fi / contact /
  phone composer, error correction), image (invert, trim), icon (weight, filled); rotation, lock, hide for all
- [x] New elements: Shape (rectangle, rounded, ellipse, line; line width, dashed, filled), Date (formats, days
  from today), Counter (next, step, digits, prefix/suffix; each printed label takes the next number)
- [x] Barcode types: Code 128, EAN-13, EAN-8, UPC-A, Code 39, ITF-14, Codabar (check digits added; bitmap in native mode)
- [x] Image crop (drag to select, move selection)
- [x] Copy / Cut / Paste elements (⌘C/⌘X/⌘V, also across templates); Copy Style / Paste Style
- [x] Templates page: category sections, coloured category chips/badges, cards with Edit / Print / trash
- [x] Home tabs: left icon sidebar on wide windows, floating bottom bar on narrow ones
- [x] Fixed: clicking an element could nudge it onto a snap guide and mark the label edited
- [x] App-styled dialogs everywhere (rename, trash, save changes, clear, delete media, calibrate, errors)
- [x] Home sidebar: Dashboard first, custom hover tips
- [x] Editor redesign 2: centred title with *, tool rail (add menu, file, page, batch, guides, element tools,
  properties toggle) with hover tips, floating per-element toolbar, align/size/arrange bar, properties panel
  with search (⌘F), category tabs and collapsible sections; theme switch applied via NSApp.appearance
- [x] Multi-select (⇧/⌘-click, box select, ⌘A): move / nudge together, align edges, distribute (3+),
  duplicate, copy/cut/paste, hide, lock, delete; floating multi-selection bar
- [x] Font search picker (text elements, inspector + floating bar), with label-friendly picks and recents
- [x] Multi-select in the Layers list (⌘-click / ⇧-click), shared with the canvas selection
- [x] Text resize = text box (wrap to width, fixed height hides overflow); font size unchanged
- [x] Canvas badge ("more") on text boxes that hide lines (not printed)
- [x] Change a template's category (card badge menu, right-click › Category, New Category…, editor Page & Media)
- [x] Sensor calibration follows the media; continuous → explained, nothing sent
- [x] Found: RP310 ignores GAPDETECT / BLINEDETECT → calibration now SIZE + GAP/BLINE + LIMITFEED + HOME
- [ ] Verify HOME calibration on the RP310 (feeds to the next label, alignment test still correct)
- [x] Leaving the editor with unsaved changes asks: Cancel · Exit Without Saving (reverts) · Save
- [x] Printer console moved out of the editor to Settings › Printers › Advanced (collapsed, with warning)
- [x] New app icon (white label printer printing a barcode label on a blue tile); app installed to /Applications
- [x] New labels save into the templates folder (Save Template dialog; Choose Location… for elsewhere);
  banner + "Move to Templates Folder" for templates stored outside it
- [x] Saved thumbnails (content-hashed PNGs in ~/Library/Caches/TPrinter/Thumbnails, pruned after 60 days unused)
- [x] Settings › Templates & files › iCloud Drive: move the templates folder to iCloud Drive and back;
  "Use This Folder" when another Mac already put templates there; iCloud placeholders are downloaded on list
- [ ] Verify iCloud sync with a second Mac
- [x] USB connection (IOUSBHost, printer-class interface, bulk OUT; auto-connect on plug-in, back to Bluetooth on unplug)
- [ ] Verify USB printing on the RP310 (does it answer on bulk IN? pacing between jobs)
- [x] Print PDF Labels (Dashboard tile, File › Print PDF Labels… ⌥⌘P): PDFs / images, one page per label,
  auto-rotate, trim, fit, sharp black, page range, copies, previews; recorded as one history batch
- [x] Default media: Shipping 3 × 3 in (76.2 × 76.2) and 2 × 3 in (50.8 × 76.2); existing libraries get them once
- [x] "Print with TPrinter" in every print window's PDF ▾ menu (alias in ~/Library/PDF Services, Settings ›
  Printing toggle); received PDFs open Print PDF Labels; optional "Print right away"
- [x] Media page redesign: grouped library with to-scale thumbnails and "In use", to-scale drawing with
  dimensions, size presets + swap, separation tiles, darkness strip, pinned save bar (unsaved / revert),
  New Label / Alignment Test / Duplicate
- [x] Units setting (mm / cm / in) in Settings › General: sizes, fields, steppers, rulers, status texts
- [x] Templates page redesign: header (location, ⌘F search, Import, New Label), "Continue where you left
  off", category chips + sort (incl. most printed) + grouping + grid / list, cards on the roll with
  hover Print (copies) / Edit, print counts, trash moved into ⋯, multi-select bar (print, category,
  export, trash), list table
- [x] History redesign: range (today / 7 / 30 days / all), Export CSV, overview (labels-per-day chart,
  totals, success rate, most printed), status + type filters, day timeline with problem reasons and
  hover Reprint / Open, detail panel (label as sent, details, reprint with copies, export, remove);
  jobs now record their type (single / batch / PDF)
- [x] Batch redesign: step tracker, template / data (delimiter, encoding) / field cards, pick a CSV
  column per field, big preview + next-rows strip, rows table with tick boxes, issue filter and empty
  cells in red (rows with missing values start unticked), pinned print bar (selected rows or range,
  copies, total, time estimate, progress + stop), sample CSV for the template
- [ ] Try a batch on the device with the new row selection / column mapping
- [x] Dashboard redesign: greeting + printer status, printer card (picture with LED, connection, last job,
  loaded media, tools / find printer), week chart + success + most printed, four main actions with
  shortcuts + tools row, continue card, recent templates (hover Print / Edit), recent activity
- [ ] Try with a real Steadfast label PDF on a parcel-size roll (check barcode scans)
- [ ] Verify EAN-13 / Code 39 scan on printed labels; verify dashed and 0.25 mm lines print cleanly

### Phase 5 — Polish (later)
- [ ] Printer status query (`~!S` / notify characteristic) — paper out, head open
- [x] Batch printing from CSV: `{{column}}` fields in any content, Batch Print… sheet (⇧⌘P)
  with field check, per-row preview, row range, copies, progress + Stop
  - Samples: `Templates/Products 30x15.tprlabel` + `Templates/Products sample.csv`
  - Multi-label jobs (several PRINTs / PRINT 1,n) misplace labels 2+ and feed blanks, even with
    SIZE switched mid-job → **one label per job** (rows and copies); 3 rows verified that way
  - RFCOMM opens occasionally hang → 3 s open timeout + retry; channel now reused across jobs
  - Next job waits for the printer's "job done" status
- [ ] Measure batch speed from the app log (target: a few seconds per label)
- [x] App icon (`scripts/make-icns.sh`)
- [ ] Developer ID signing + notarization
- [ ] Optional Xcode project if Xcode gets installed

## Open questions / risks
- Exact BLE characteristic UUID for the RP310 — auto-detected, needs confirmation.
- Whether the RP310 is in TSPL (label) mode or ESC/POS (receipt) mode by default —
  some Rongta units switch modes via a button combo or utility app.
- BLE throughput: large bitmaps (e.g. 100×150 mm) take several seconds; tune chunk size.
