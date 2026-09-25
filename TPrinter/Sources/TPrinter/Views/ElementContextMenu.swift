import SwiftUI

/// Right-click menu for an element, used on the canvas and in the layers list.
struct ElementContextMenu: View {
    let element: LabelElement
    let session: LabelSession
    var select: (LabelElement.ID?) -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil") {
            select(element.id)
            session.renamingElementID = element.id
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            select(session.duplicateElement(element.id))
        }

        Divider()

        Button("Cut", systemImage: "scissors") {
            session.cutElement(element.id)
            select(nil)
        }
        Button("Copy", systemImage: "doc.on.doc") { session.copyElement(element.id) }
        Button("Paste", systemImage: "doc.on.clipboard") { select(session.pasteElements()) }
            .disabled(!ElementClipboard.hasElements())
        Button("Copy Style", systemImage: "paintbrush") { session.copyStyle(element.id) }
        Button("Paste Style", systemImage: "paintbrush.pointed.fill") { session.pasteStyle(onto: element.id) }
            .disabled(!(ElementClipboard.style().map(element.acceptsStyle(of:)) ?? false))

        Divider()

        Menu("Arrange") {
            ForEach(Arrangement.allCases, id: \.self) { arrangement in
                Button(arrangement.title) { session.arrange(element.id, arrangement) }
                    .disabled(isAtLimit(arrangement))
            }
        }

        Menu("Align on Label") {
            ForEach(LabelAlignment.allCases, id: \.self) { alignment in
                Button(alignment.title, systemImage: alignment.systemImage) {
                    session.align(element.id, alignment, elementSize: ElementGeometry.sizeMM(of: element))
                }
            }
        }

        switch element.kind {
        case .image:
            Button("Replace Image…", systemImage: "photo.badge.arrow.down") { replaceImage() }
        case .text:
            Toggle("Shrink to Fit", isOn: Binding {
                element.shrinksToFit
            } set: { on in
                var edited = element
                if on, !element.shrinksToFit {
                    edited.fitWidthMM = max(2, ((session.document.widthMM - element.x - 0.5) * 2).rounded() / 2)
                }
                edited.shrinksToFit = on
                session.updateElement(edited, actionName: on ? "Shrink to Fit" : "Don't Shrink")
            })
        case .counter:
            Button("Reset Counter to 1", systemImage: "arrow.counterclockwise") {
                var edited = element
                edited.counterNext = 1
                session.updateElement(edited, actionName: "Reset Counter")
            }
        default:
            EmptyView()
        }

        Divider()

        Button("Delete", systemImage: "trash", role: .destructive) {
            session.deleteElement(element.id)
            select(nil)
        }
    }

    /// Front-most can't go further forward; back-most can't go further back.
    private func isAtLimit(_ arrangement: Arrangement) -> Bool {
        let elements = session.document.elements
        switch arrangement {
        case .front, .forward: return elements.last?.id == element.id
        case .back, .backward: return elements.first?.id == element.id
        }
    }

    private func replaceImage() {
        let label = CGSize(width: session.document.widthMM, height: session.document.heightMM)
        guard let url = ImageImport.chooseFile(),
              let replacement = try? ImageImport.element(from: url, label: label) else { return }
        var edited = element
        edited.imageData = replacement.imageData
        edited.content = replacement.content
        edited.dithers = replacement.dithers
        edited.imageThreshold = replacement.imageThreshold
        edited.imageWidthMM = replacement.imageWidthMM
        session.updateElement(edited, actionName: "Replace Image")
    }
}
