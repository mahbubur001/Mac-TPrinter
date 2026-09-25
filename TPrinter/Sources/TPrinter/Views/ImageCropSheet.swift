import AppKit
import SwiftUI

/// Crop a picture: drag on it to draw the part to keep, or drag inside the selection to move it.
/// `crop` is a unit rect (0…1, origin top-left) of the original picture.
struct ImageCropSheet: View {
    let data: Data
    @State var crop: CGRect
    var onDone: (CGRect?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart: CGRect?

    private static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let minimum: CGFloat = 0.03

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Crop Image").font(.headline)
                Spacer()
                Text("Drag to select the part to keep").font(.callout).foregroundStyle(.secondary)
            }
            if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 {
                let fitted = fittedSize(image.size, in: CGSize(width: 460, height: 340))
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                    .overlay { selection(in: fitted) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: fitted))
                    .background(Checkerboard())
                    .frame(width: 460, height: 340)
            }
            HStack {
                Button("Reset") { crop = Self.full }
                    .disabled(crop == Self.full)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Crop") {
                    onDone(crop == Self.full ? nil : crop)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func selection(in size: CGSize) -> some View {
        let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the selection.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                let now = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                if dragStart == nil { dragStart = crop }
                guard let original = dragStart else { return }
                if original != Self.full, original.contains(start) {
                    // Move the selection, kept inside the picture.
                    var moved = original.offsetBy(dx: now.x - start.x, dy: now.y - start.y)
                    moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                    crop = moved
                } else {
                    let a = clamp(start), b = clamp(now)
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    if rect.width >= Self.minimum, rect.height >= Self.minimum { crop = rect }
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func fittedSize(_ size: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// Grey checks behind transparent pictures.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.15)))
                }
            }
        }
    }
}

extension LabelElement {
    /// Sets the crop (unit rect of the original picture); nil shows the whole picture.
    mutating func setCrop(_ rect: CGRect?) {
        let crop = rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        cropX = crop.minX
        cropY = crop.minY
        cropWidth = crop.width
        cropHeight = crop.height
    }
}
