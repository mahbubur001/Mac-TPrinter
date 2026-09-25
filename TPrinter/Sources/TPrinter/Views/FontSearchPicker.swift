import AppKit
import SwiftUI

/// Font chooser with search: a button showing the current font that opens a popover listing
/// label-friendly picks, recently used fonts and every installed family, each drawn in its own face.
struct FontSearchPicker: View {
    @Binding var selection: String
    var width: CGFloat = 170
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text(FontChoices.title(selection))
                    .font(FontChoices.preview(selection, size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: 26)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FontSearchList(selection: $selection) { isOpen = false }
        }
        .accessibilityLabel("Font: \(FontChoices.title(selection))")
    }
}

private struct FontSearchList: View {
    @Binding var selection: String
    var onPick: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("recentFonts") private var recentList = ""

    private var recents: [String] { recentList.split(separator: "|").map(String.init).filter(FontChoices.exists) }

    private func matches(_ name: String) -> Bool {
        query.isEmpty || FontChoices.title(name).localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(query)
    }

    private var sections: [(title: String, fonts: [String])] {
        let picks = FontChoices.recommended.filter(matches)
        let recent = recents.filter { matches($0) && !FontChoices.recommended.contains($0) }
        let all = FontChoices.installed.filter(matches)
        if !query.isEmpty {
            var seen = Set<String>()
            return [("Results", (picks + recent + all).filter { seen.insert($0).inserted })]
        }
        return [("Good for labels", picks), ("Recently used", recent), ("All fonts", all)].filter { !$0.fonts.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = sections.first?.fonts.first { pick(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.fonts, id: \.self) { name in row(name) }
                        } header: {
                            Text(section.title.uppercased())
                                .font(.system(size: 10, weight: .bold)).kerning(0.5)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                                .background(.regularMaterial)
                        }
                    }
                    if sections.isEmpty {
                        Text("No fonts match “\(query)”.").foregroundStyle(.secondary).padding(20)
                    }
                }
            }
        }
        .frame(width: 300, height: 400)
        .onAppear { searchFocused = true }
    }

    private func row(_ name: String) -> some View {
        Button { pick(name) } label: {
            HStack {
                Text(FontChoices.title(name)).font(FontChoices.preview(name, size: 15)).lineLimit(1)
                Spacer()
                if name == selection { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.system(size: 11, weight: .bold)) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(name == selection ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(FontRowStyle())
    }

    private func pick(_ name: String) {
        selection = name
        var list = recents.filter { $0 != name }
        list.insert(name, at: 0)
        recentList = list.prefix(6).joined(separator: "|")
        onPick()
    }
}

private struct FontRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

/// The font values a text element can hold: the four system designs plus installed family names.
enum FontChoices {
    static let designs = ["system", "rounded", "serif", "monospaced"]

    /// Bold, even-stroke fonts that print well at 203 dpi (only those installed are listed).
    static var recommended: [String] {
        (["system", "rounded", "monospaced"] + ["DIN Condensed", "DIN Alternate", "Helvetica Neue", "Arial", "Avenir Next Condensed",
                                                  "Futura", "Menlo", "Arial Rounded MT Bold"]).filter(exists)
    }

    static var installed: [String] { TextFit.installedFamilies }

    static func exists(_ name: String) -> Bool {
        designs.contains(name) || NSFontManager.shared.availableFontFamilies.contains(name)
    }

    static func title(_ name: String) -> String {
        switch name {
        case "system": "System"
        case "rounded": "Rounded"
        case "serif": "Serif"
        case "monospaced": "Monospaced"
        default: name
        }
    }

    static func preview(_ name: String, size: CGFloat) -> Font {
        switch name {
        case "system": .system(size: size)
        case "rounded": .system(size: size, design: .rounded)
        case "serif": .system(size: size, design: .serif)
        case "monospaced": .system(size: size, design: .monospaced)
        default: .custom(name, size: size)
        }
    }
}
