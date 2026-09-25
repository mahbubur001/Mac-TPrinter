import SwiftUI

/// The home screens: app header (icon + name, notifications, settings), the selected tab, and the
/// floating tab bar at the bottom.
struct HomeView: View {
    let tab: HomeTab
    @EnvironmentObject private var session: LabelSession
    @EnvironmentObject private var notices: NoticeCenter
    @State private var showsNotices = false

    /// Wider than this, the tabs move from the floating bottom bar to a sidebar on the left.
    static let sidebarMinWidth: CGFloat = 1000

    var body: some View {
        GeometryReader { geometry in
            let usesSidebar = geometry.size.width >= Self.sidebarMinWidth
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    HStack(spacing: 0) {
                        if usesSidebar {
                            TabSidebar(selection: tab) { session.route = .home($0) }
                                .zIndex(1) // tips draw over the content
                            Divider()
                        }
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if !usesSidebar {
                    TabBar(selection: tab) { session.route = .home($0) }
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: usesSidebar)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 26)
            Text("TPrinter").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                showsNotices.toggle()
                notices.markAllRead()
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if notices.unread > 0 {
                            Text("\(min(notices.unread, 9))")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(.red, in: Circle())
                                .offset(x: 2, y: -1)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .focusable(false) // never the window's first key view (that drew a blue ring on launch)
            .help("Notifications")
            .popover(isPresented: $showsNotices, arrowEdge: .bottom) { NoticesPopover() }
            Button { session.route = .home(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 30)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Settings")
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 14)
        .focusEffectDisabled() // no blue focus ring around the bell / gear when the window opens
        .frame(height: 52)
        .background(WindowDragArea())
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .dashboard: DashboardTab()
        case .templates: TemplatesTab()
        case .batch: BatchTab()
        case .history: HistoryTab()
        case .settings: SettingsTab()
        }
    }
}

/// Icon sidebar with the five home tabs, for wide windows.
struct TabSidebar: View {
    let selection: HomeTab
    var select: (HomeTab) -> Void

    /// Dashboard first in the sidebar (the bottom bar keeps it in the centre).
    static let order: [HomeTab] = [.dashboard, .templates, .batch, .history, .settings]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { index, tab in
                SidebarItem(tab: tab, shortcut: index + 1, isOn: tab == selection) { select(tab) }
            }
            Spacer()
        }
        .padding(.top, 14)
        .focusEffectDisabled()
        .frame(width: 70)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}

private struct SidebarItem: View {
    let tab: HomeTab
    let shortcut: Int
    let isOn: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 17, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 46, height: 46)
                .background(isOn ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.07) : .clear),
                            in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .hoverTip(tab.title, shortcut: "⌘\(shortcut)")
    }
}

/// Floating bar with the five home tabs.
struct TabBar: View {
    let selection: HomeTab
    var select: (HomeTab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(HomeTab.allCases) { tab in
                let isOn = tab == selection
                Button { select(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 16, weight: isOn ? .semibold : .regular))
                            .frame(width: 44, height: 26)
                            .background(isOn ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        Text(tab.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(minWidth: 78)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\((HomeTab.allCases.firstIndex(of: tab) ?? 0) + 1)")), modifiers: .command)
                .help("\(tab.title) (⌘\((HomeTab.allCases.firstIndex(of: tab) ?? 0) + 1))")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(6)
        .focusEffectDisabled()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 5)
    }
}

private struct NoticesPopover: View {
    @EnvironmentObject private var notices: NoticeCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications").font(.headline)
                Spacer()
                if !notices.notices.isEmpty { Button("Clear") { notices.clear() }.buttonStyle(.link) }
            }
            .padding(12)
            Divider()
            if notices.notices.isEmpty {
                Text("Nothing new. Print results and printer connections show up here.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notices.notices) { notice in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(color(notice.kind)).frame(width: 8, height: 8).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notice.title).fontWeight(.medium)
                                    if !notice.detail.isEmpty { Text(notice.detail).font(.caption).foregroundStyle(.secondary) }
                                    Text(notice.date.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    private func color(_ kind: AppNotice.Kind) -> Color {
        switch kind {
        case .success: Theme.ledReady
        case .info: .accentColor
        case .warning: Theme.ledBusy
        case .problem: .red
        }
    }
}
