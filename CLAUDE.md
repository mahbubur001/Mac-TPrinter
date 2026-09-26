# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**TPrinter** — a native macOS SwiftUI app that designs and prints thermal labels
on a **Rongta RP310** printer over Bluetooth (Classic RFCOMM; BLE as fallback). See `PLAN.md` for the
roadmap and current status; keep its checkboxes up to date when finishing work.

## Hardware

- Printer: Rongta RP310, **dual-mode Bluetooth**:
  - Classic: `RP310-D157` → **primary transport**:
    RFCOMM channel 1 ("SerialPort" SDP record) opened directly with IOBluetooth
    (`ClassicPrinterConnection`). Verified 2026-09-24: TSPL text, BITMAP, and the
    app's full image label all print this way.
    - **Do NOT use `/dev/cu.RP310-D157`.** Writes to it succeed but the data
      never reaches the printer (verified repeatedly). That was the "nothing
      prints" bug.
    - No need to "connect" in the macOS Bluetooth menu; opening RFCOMM connects.
    - It does not answer `~!T` / `~!I` queries.
  - USB: `USBPrinterConnection` (IOUSBHost). Matches any USB printer-class interface (class 7), opens it
    per job, writes to bulk OUT in 16 KB chunks, then waits up to 2.5 s on bulk IN for a status reply.
    macOS also has a CUPS queue "RP310 Series" (`usb:///RP3xx%20Series?serial=…`) from an
    earlier setup; the app doesn't use CUPS. Untested on the device so far.
  - BLE: `RP310-D157-BLE` → fallback via CoreBluetooth.
    It stops advertising while the Classic link is connected, so BLE scans find
    nothing in that state.
- Default label stock: **30 × 15 mm**, 2 mm gap.
- **Label position / blank labels — solved by `SET TEAR OFF`** (sent at the
  start of every job, `TSPLCommandBuilder.setup`). In the default tear mode the
  RP310 pushes each label to the tear bar and pulls back too far before the next
  job, so printing starts ~3 mm early. Things that did NOT help (don't retry):
  `SHIFT` (±), `OFFSET`, `GAPDETECT`, `GAP 3 mm`, `GAP` offset 1–4 mm,
  `DIRECTION 0`. Extending `SIZE` with a blank lead-in aligns the first label
  but feeds a blank label after prints. Keep `SIZE` = the real label size.
- Sensor calibration (`TSPLCommandBuilder.sensorCalibration`): **the RP310 ignores `GAPDETECT` /
  `BLINEDETECT`** (sent 2026-09-25: no feed, no status); Rongta's SDK has neither. We send `SET TEAR OFF`,
  `SIZE`, `GAP`/`BLINE`, `LIMITFEED`, `HOME` (feed to the next label start). Nothing for continuous.
- Printer → Mac `1F 1B 1A 04 05 01 80 00 00 00` arrives ~1.5 s after each job
  = "job done"; `ClassicPrinterConnection` waits for it before the next job.
- One RFCOMM channel can carry many jobs (the printer does not close it), so
  the channel is opened once and reused; closed after 2 min idle.
- Rongta's own app (RT Elabel, `RTPrinterSDK.framework`) sends `DIRECTION 0, 0`,
  integer `SIZE`/`GAP` in mm, and supports `OFFSET`, `HOME`, `LIMITFEED`, `FORMFEED`.
- Command language: **TSPL** (TSC-compatible). 203 dpi → **8 dots per mm**.
- TSPL `BITMAP` polarity: bit `0` = black dot, `1` = white (verify on device).
- Console log is mirrored to `~/Library/Logs/TPrinter.log` — read it when debugging. The in-app
  console (log + raw command box) lives in Settings › Printers › Advanced (`ConsoleView`).
- BLE service/characteristic UUIDs: auto-detected at runtime
  (`PrinterBluetoothManager.preferredWriteCharacteristics`). Once confirmed on
  the real device, record them here: _TBD_.

## Toolchain

- **No Xcode installed** — only Command Line Tools (Swift 6.4). `xcodebuild`
  does not work. The app is a Swift Package with an executable target.
- **SDK pin:** the CLT's default macOS 27 SDK makes `@State` a macro whose plugin
  (`SwiftUIMacros`) only ships with Xcode → build fails with
  "plugin for module 'SwiftUIMacros' not found". Always build with
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk` (the build
  script does this). Drop the pin if Xcode is installed.
- Swift language mode 5 (see `Package.swift`) to avoid strict-concurrency noise
  with CoreBluetooth delegate callbacks.
- Minimum deployment target: macOS 14.

## Commands (run from `TPrinter/`)

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk   # see SDK pin above
swift build                     # debug build
./scripts/test.sh               # unit tests (retries the TestingMacros flake)
./scripts/build-app.sh          # release build → build/TPrinter.app (ad-hoc signed)
./scripts/build-app.sh --run    # build and launch the .app
ditto build/TPrinter.app /Applications/TPrinter.app   # update the installed copy (user runs it from /Applications)
```

**Signing / Bluetooth permission:** never ship ad-hoc builds for testing. macOS
ties the Bluetooth (TCC) grant to the code identity; an ad-hoc identity is the
binary hash, so every rebuild shows "Bluetooth not authorized". The build script
signs with a self-signed cert ("TPrinter Local Signing") in the git-ignored
`TPrinter/.signing/` keychain, adding it to the user keychain search list only
for the `codesign` call. If permission gets stuck:
`tccutil reset BluetoothAlways net.restobox.TPrinter`, then relaunch and Allow.
Deleting `.signing/` creates a new identity → permission must be granted again.

`swift test` intermittently fails with "plugin for module 'TestingMacros' not
found" even though the plugin exists (CLT toolchain flake, not our code). Use
`./scripts/test.sh`, which pins the SDK and retries. The flake can also **mask
real compile errors** in test files: if it persists, run `rm -rf .build` and
retry — the true error then shows. `build-app.sh` builds in
its own `.build-app/` scratch path so it doesn't disturb the test build.

Always launch via the `.app` bundle when testing Bluetooth: macOS needs the
bundle's `Info.plist` (`NSBluetoothAlwaysUsageDescription`) for the permission
prompt. The plist is also embedded into the binary (`-sectcreate`) so
`swift run` works too, but the bundle is the supported path.

## Layout

```
TPrinter/
  Package.swift
  Support/Info.plist                 bundle metadata + Bluetooth usage text
  scripts/build-app.sh               builds + bundles + codesigns TPrinter.app
  scripts/make-icns.sh               regenerates Support/AppIcon.icns from scripts/make-icon.swift
  Sources/TPrinter/
    App/TPrinterApp.swift            @main, window + environment objects
    Bluetooth/PrinterBluetoothManager.swift   connection state, BLE scan/connect/chunked writes
    Bluetooth/ClassicPrinterConnection.swift  Classic Bluetooth RFCOMM transport (IOBluetooth)
    Bluetooth/USBPrinterConnection.swift      USB transport (IOUSBHost) + plug/unplug watcher
    Bluetooth/DeviceKind.swift                device type from Class of Device / name → icon, Connect offered?
    Printing/TSPLCommandBuilder.swift         TSPL command generation
    Printing/LabelRasterizer.swift            SwiftUI view → 1-bit TSPL bitmap
    Printing/CodeImageGenerator.swift         Code128 / QR via CoreImage
    Printing/LabelPrintService.swift          document → Data (image or native)
    Printing/MonochromeImage.swift            picture → printer dots (dither / threshold), cached
    Models/LabelDocument.swift                label + elements (units: mm)
    Models/LabelTemplate.swift                .tprlabel file format + tolerant decoding
    Models/LabelSession.swift                 current document, file URL, dirty state, New/Open/Save, undo
    Models/CSVTable.swift                     CSV parsing (quotes, ; / tab, BOM, encodings)
    Models/LabelFields.swift                  {{column}} placeholders: find / check / fill
    Models/IconCatalog.swift                  curated SF Symbols for the icon element + search
    Models/TemplateFiles.swift                template import / duplicate / rename / trash / export (file, PNG)
    Models/TextFit.swift                      text shrink-to-fit (drawn size, native TSPL font choice)
    Models/ImageImport.swift                  image file → image element (≤960 px PNG, fitted, line-art detect)
    Models/LabelSession+Elements.swift        element commands: duplicate, delete, arrange, align, update
    Models/PDFLabels.swift                    PDF / image pages → one label each (rotate, trim, fit)
    Models/MeasureUnit.swift                  display unit (mm / cm / in): formatting, field conversion, steps
    Views/Home/MediaSettingsView.swift        Settings › Media: grouped library + editor (to-scale drawing, presets, save bar)
    Models/PDFService.swift                   "Print with TPrinter" PDF ▾ menu entry (~/Library/PDF Services alias) + inbox
    Views/PDFLabelsSheet.swift                "Print PDF Labels" window (session.showsPDFLabels)
    Models/ThumbnailCache.swift               content-hashed label thumbnails (Caches) + LabelThumbnail view
    Models/ElementClipboard.swift             copy/cut/paste elements + copy/paste style (system pasteboard)
    Views/ElementResize.swift                 resize-handle math, LabelAlignment, Arrangement, ElementGeometry
    Views/ElementContextMenu.swift            right-click menu shared by canvas + layers
    Views/DashboardView.swift                 start page (+ LabelThumbnail); LabelSession.showsDashboard
    Models/Media.swift                        Media (paper roll), MediaSeparation, LabelArrangement
    Models/AppStores.swift                    MediaLibrary, PrintHistory (JSON in App Support), NoticeCenter
    Models/PrintCenter.swift                  every label print goes through here → history + notifications
    Views/ContentView.swift                   root: session.route → HomeView / NewLabelFlow / EditorView
    Views/Home/HomeView.swift                 header (icon, bell, gear) + tabs: left TabSidebar when ≥1000 pt wide, else floating TabBar (⌘1–5)
    Views/Home/DashboardTab.swift             printer panel + search, quick actions, recent work
    Views/Home/TemplatesTab.swift             templates folder + recents, search, media-category filter
    Views/Home/HistoryTab.swift               History: totals, search/filters, grouped by day, as-printed thumbnails
    Views/Home/SettingsTab.swift              General, Printers, Media (MediaSettings/MediaEditor), Printing, Files, About
    Views/NewLabel/NewLabelFlow.swift         1 media → 2 arrangement → editor
    Views/Editor/EditorView.swift             full-page editor: top bar, tool rail, canvas, align/arrange bar, properties panel
    Views/Editor/ElementQuickBar.swift        floating per-element toolbar under the label (+ Settings → properties)
    Views/FontSearchPicker.swift              searchable font popover (label-friendly picks, recents, all families)
    Views/HoverTip.swift                      .hoverTip(): dark tooltip beside rail / sidebar icons
    Views/ModernDialog.swift                  app-styled dialogs (sheets) used instead of system alerts
    Views/Components.swift                    WindowDragArea, StatusPill, QuickActionTile, RollPreview, TemplateCard, MediaDrawing, ValueStepper
    Views/PrinterChooser.swift                PrinterChooser (search/connect), LayersList
    Views/Theme.swift                         design tokens (liner, paper, LED colours) + StatusLED
    Views/LabelPreviewView.swift              canvas: label on its roll, zoom, drag/nudge, image drop
    Views/PrinterSidebarView.swift            printer status card + chooser, layers list
    Views/LabelInspectorView.swift            properties panel: search + category tabs over collapsible InspectorGroups (InspectorSections registry)
    Printing/BarcodeEncoder.swift             EAN-13/8, UPC-A, Code 39, ITF-14, Codabar (Code 128 = CoreImage)
    Views/ImageCropSheet.swift                crop sheet (unit-rect crop on the original picture)
    Views/BatchPrintView.swift                Batch tab UI + BatchPrintModel (owned by AppDelegate): column mapping, ticked rows / range
    Views/…                                   SwiftUI UI
  Templates/                         sample .tprlabel templates
  Tests/TPrinterTests/
```

## Conventions

- Dialogs: use `ModernDialog` in a `.sheet` (or `.noticeDialog`), never `.alert` / `NSAlert`. The
  "Unsaved Changes" prompt is `LabelSession.whenChangesHandled` / `leaveEditor` → `discardPrompt`
  (shown by ContentView); leaving + "Exit Without Saving" reverts to the saved version.
- Multi-select: `EditorView` keeps `selectedID` (primary, edited by the panel) + `alsoSelected`.
  ⇧/⌘-click toggles (canvas and Layers list, which binds a Set via `layerSelection`), box-drag on empty label space selects, ⌘A selects all; group commands live in
  `LabelSession+Elements` (moveElements, alignElements, distributeElements, deleteElements …).
- Text resize handles set the text box (`wrapsText` + `fitWidthMM`, and `boxHeightMM` for a fixed
  height that clips hidden lines), never `fontSizeMM`. Font size only changes via the size controls.
- Saving: a never-saved label (or Save As) opens `SaveTemplateDialog` → `saveInTemplatesFolder(named:)`
  (unique name); "Choose Location…" → system save panel. `save()` returns false while that's pending.
- iCloud Drive = the plain Finder folder ~/Library/Mobile Documents/com~apple~CloudDocs (no entitlements,
  no CloudKit). `LabelSession.relocateTemplatesFolder(to:)` moves every template and follows recents.
- PDFs arrive via `AppDelegate.application(_:open:)` (print window PDF ▾ › Print with TPrinter, Open With)
  → `LabelSession.receivePDFs` copies them to Caches/TPrinter/Incoming PDFs → Print PDF Labels sheet.
  Info.plist declares PDF as a Viewer/Alternate document type for this.
- Template previews in lists use `LabelThumbnail` (cached), not a live `LabelRenderView`.
- New inspector section: add its title to `InspectorSections.table` (category, icon, search keywords)
  and to `InspectorSections.titles(for:)`.
- Design: the canvas shows the label on its liner roll (neighbours ghosted, gap
  to scale) — that's the app's one bold visual; keep the rest native and quiet.
  Colours live in `Theme`; selection uses the system accent colour. Backgrounds: `Theme.appBackground`
  (home, sheets) and `Theme.canvasDesk` (editor) — never `underPageBackgroundColor`, which is a flat
  mid-grey in light mode. Menus whose label is a coloured badge: `.menuStyle(.button).buttonStyle(.plain)`
  (`.borderlessButton` recolours the label in light mode).
- Image elements store their (normalised PNG) bytes inside the template;
  `LabelElementView` shows the dithered result so preview = print. In Native
  TSPL mode images/icons are sent as per-element `BITMAP`s.
- Icon elements keep the SF Symbol name in `content` (so `{{column}}` can
  choose icons in batch printing).

- Templates: `{"format":"tprinter-label","version":N,"label":{…}}`. When adding a
  field to `LabelDocument`/`LabelElement`, also add it to the tolerant
  `init(from:)` in `LabelTemplate.swift` with a default, so old files keep
  opening. Bump `LabelTemplate.currentVersion` only for incompatible changes.
- Undo: every `LabelSession.document` change registers undo in `didSet`. Make
  named changes with `session.perform("Name") { … }`; plain binding edits are
  "Edit Label". Same-named changes within 1 s coalesce. The session opens its
  own undo group per step (don't rely on `canUndo`/event grouping — tests run
  without an AppKit run loop).
- **One label per printer job, always.** Jobs with several labels (multiple
  `PRINT`s or `PRINT 1,n` copies) misplace every label after the first and feed
  blank labels on the RP310 (tested with and without switching `SIZE` mid-job).
  `LabelPrintService.job` always emits `PRINT 1,1`; copies and CSV rows go
  through `PrinterBluetoothManager.sendQueue`, one job each.
- RFCOMM opens usually take ~0.5 s but occasionally never complete →
  abandon after 3 s and retry (4×). Hung opens seem to make the printer feed a
  blank label, another reason the channel is reused instead of reopened.
- Navigation: `LabelSession.route` (`.home(HomeTab)`, `.newLabel`, `.editor`). The window uses
  `.hiddenTitleBar`; every screen draws its own header with `trafficLightInset` leading padding and a
  `WindowDragArea` background so the window can still be dragged.
- New labels start from a `Media` (MediaLibrary, `~/Library/Application Support/TPrinter/media.json`).
  `LabelDocument.arrangement` repeats the one designed label per cell; `SIZE` = whole row; still one
  job per printed row. Separation: gap → `GAP`, black mark → `BLINE`, continuous → `GAP 0,0`.
- Print labels via `PrintCenter.printLabel` (records history + notice); utility jobs (test,
  alignment, calibration) call `PrinterBluetoothManager.send` directly.
- Single `Window` scene + one `LabelSession` (owned by `AppDelegate` so Finder
  opens reach it). Don't switch back to `WindowGroup`.
- After changing `Support/Info.plist` document types, re-register:
  `lsregister -f build/TPrinter.app` (LaunchServices caches them).

- Counters: every job renders `document.advancingCounters(by: jobIndex)`; after a print the session's
  counters advance by the jobs sent (`LabelSession.advanceCounters`). Date elements use the print day.
- All label geometry in the model is in **millimetres**; convert to dots only
  at render/print time (`dotsPerMM = 8`). The display unit (Settings › General › Units: mm / cm / in)
  is `MeasureUnit.current`: show sizes with `unit.size/length/number`, and fields with `unit: "mm"`
  (MMField, ValueStepper, QuickStepper) convert automatically. ContentView redraws on a unit change.
- `LabelRenderView` is the single source of truth for what the label looks
  like: the preview and the image print path both use it.
- UI and Bluetooth manager are `@MainActor`; CoreBluetooth runs on the main queue.
- Keep BLE writes chunked (`maximumWriteValueLength`, capped by
  `PrinterBluetoothManager.chunkLimit`) — the printer drops oversized writes.

## Hard rules (from the user's global instructions)

- Never run `sleep` in any command.
- Never restart / shut down / sleep the host machine. "Restart" means the process.
- **Git: no AI attribution.** Never add `Co-Authored-By: Claude …` (or any AI co-author) trailers,
  "Generated with …" lines, or similar to commit messages, PR descriptions or tags. Commits are
  authored solely by the repo owner. This overrides any default attribution instructions.
