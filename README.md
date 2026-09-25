# TPrinter

A native macOS app for designing and printing thermal labels on a **Rongta RP310** label printer —
over Classic Bluetooth, Bluetooth LE or USB.

Design a label on screen, and what you see is what prints: the preview and the print path render
the same view at the printer's 203 dpi. Labels are sent as TSPL (TSC-compatible) commands, one
label per job.

## Features

- **Label editor**
  - Elements: text, barcodes (Code 128, EAN-13, EAN-8, UPC-A, Code 39, ITF-14, Codabar), QR codes
    (link, text, Wi-Fi, contact, phone), images (dithered or line art, crop, invert), icons (SF
    Symbols), shapes, date and counter
  - Text boxes that wrap and clip, shrink-to-fit, fonts with search, white-on-black, outline
  - Drag, resize handles, snap guides, rulers, safe margin, arrow-key nudging
  - Multi-select (⇧/⌘-click, box select), align and distribute, layers, lock / hide
  - Copy / paste elements and styles, undo / redo, floating per-element toolbar, searchable
    properties panel
- **Templates** — `.tprlabel` files (JSON) in a templates folder, grouped by category, with saved
  thumbnails; import, export (file or PNG), duplicate, rename; optional iCloud Drive folder
- **Batch printing** from CSV: put `{{column}}` in any text, barcode or QR content
- **Media library** — label sizes, gap / black mark / continuous, labels across, darkness, speed
- **Print history**, notifications, alignment test, sensor calibration, dark / light theme

## Requirements

- macOS 14 or later
- Xcode **or** just the Command Line Tools (`xcode-select --install`) with Swift 6
- A Rongta RP310 (other TSPL printers may work but aren't tested)

## Build and run

The app is a Swift package with an executable target. From the `TPrinter/` folder:

```bash
./scripts/build-app.sh --run    # release build → build/TPrinter.app, signed, then launched
./scripts/test.sh               # unit tests
```

To install it like any other app:

```bash
ditto build/TPrinter.app /Applications/TPrinter.app
```

Notes:

- **SDK pin.** With only the Command Line Tools installed, the macOS 27 SDK needs a SwiftUI macro
  plugin that ships with Xcode, so the scripts build against the macOS 26 SDK
  (`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`). For a plain `swift build`,
  export that first.
- **Signing.** `build-app.sh` creates a self-signed certificate in `TPrinter/.signing/` (git-ignored)
  the first time. macOS ties the Bluetooth permission to the app's signing identity, so a stable
  identity means you allow Bluetooth once, not after every build.
- **Tests.** `test.sh` retries a known Command Line Tools flake ("plugin for module
  'TestingMacros' not found").

## Connecting the printer

- **Bluetooth (recommended):** pair the printer in System Settings › Bluetooth, then open TPrinter
  and pick it on the Dashboard or in Settings › Printers. The app talks to it directly over an RFCOMM
  channel; no macOS printer driver is needed. Allow Bluetooth access when asked.
- **USB:** plug the printer in with a data cable; TPrinter switches to it automatically.
- Every job starts by turning the printer's tear mode off (`SET TEAR OFF`), which keeps labels
  aligned on the RP310.

## Project layout

```
TPrinter/
  Package.swift
  Sources/TPrinter/
    App/         app entry point
    Bluetooth/   Classic Bluetooth (IOBluetooth), BLE (CoreBluetooth) and USB (IOUSBHost) transports
    Printing/    TSPL commands, rendering to printer dots, barcode encoders
    Models/      label document, templates, media, history, CSV, thumbnails
    Views/       SwiftUI screens: home tabs, editor, inspector, dialogs
  Tests/TPrinterTests/
  Support/       Info.plist, app icon
  Templates/     sample template and CSV
  scripts/       build, test and icon scripts
```

`CLAUDE.md` has detailed notes on the printer's behaviour and the code's conventions; `PLAN.md`
tracks what's done and what's left.

## License

MIT — see [LICENSE](LICENSE).
