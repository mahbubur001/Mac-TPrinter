import Foundation

/// Where TPrinter keeps its own data: ~/Library/Application Support/TPrinter.
enum AppStorageLocation {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Default folder for saved templates: ~/Documents/TPrinter Templates.
    static var defaultTemplatesFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TPrinter Templates", isDirectory: true)
    }

    /// The iCloud Drive folder in Finder (~/Library/Mobile Documents/com~apple~CloudDocs), or nil
    /// when iCloud Drive is off on this Mac.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// Templates folder in iCloud Drive: "iCloud Drive/TPrinter Templates".
    static var iCloudTemplatesFolder: URL? {
        iCloudDrive?.appendingPathComponent("TPrinter Templates", isDirectory: true)
    }

    static func isInICloudDrive(_ url: URL) -> Bool {
        guard let root = iCloudDrive?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(root)
    }
}

/// Small JSON-file persistence shared by the stores below.
private struct JSONFile<Value: Codable> {
    let url: URL

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}

// MARK: - Media library

/// The user's paper rolls. Seeded with common stock on first launch.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var media: [Media]
    private let file: JSONFile<[Media]>

    init(directory: URL = AppStorageLocation.directory, defaults: UserDefaults = .standard) {
        file = JSONFile(url: directory.appendingPathComponent("media.json"))
        if let saved = file.load() {
            media = saved
            addLaterStarters(defaults: defaults)
        } else {
            media = Media.starters
            defaults.set(Media.laterStarters, forKey: Self.offeredStartersKey) // already included
        }
    }

    private static let offeredStartersKey = "mediaStartersOffered"

    /// New built-in sizes for libraries created before they existed, each offered once.
    private func addLaterStarters(defaults: UserDefaults) {
        var offered = Set(defaults.stringArray(forKey: Self.offeredStartersKey) ?? [])
        var changed = false
        for name in Media.laterStarters where !offered.contains(name) {
            offered.insert(name)
            guard media(named: name) == nil, let starter = Media.starters.first(where: { $0.name == name }) else { continue }
            // Next to the other media of its category.
            let index = media.lastIndex { $0.category.caseInsensitiveCompare(starter.category) == .orderedSame }.map { $0 + 1 } ?? media.count
            media.insert(starter, at: index)
            changed = true
        }
        defaults.set(Array(offered).sorted(), forKey: Self.offeredStartersKey)
        if changed { file.save(media) }
    }

    /// Categories in first-seen order.
    var categories: [String] {
        var seen = Set<String>()
        return media.map(\.category).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func media(inCategory category: String?) -> [Media] {
        guard let category else { return media }
        return media.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
    }

    func media(named name: String) -> Media? { media.first { $0.name == name } }

    /// Adds a new media or replaces the one with the same id.
    func save(_ item: Media) {
        if let index = media.firstIndex(where: { $0.id == item.id }) {
            media[index] = item
        } else {
            media.append(item)
        }
        file.save(media)
    }

    func delete(_ id: Media.ID) {
        media.removeAll { $0.id == id }
        file.save(media)
    }
}

// MARK: - Print history

struct PrintRecord: Identifiable, Codable, Hashable {
    enum Result: String, Codable { case printed, stopped, failed }

    var id = UUID()
    var date: Date
    var templateName: String
    var labels: Int
    var mediaName: String
    var printer: String
    var result: Result
    var detail: String = ""
    var wasBatch: Bool = false
    /// The label as printed (template JSON), for Reprint.
    var template: Data?
    /// Single label, CSV batch or PDF labels. Missing in older records (see `jobKind`).
    var kind: Kind?

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case single, batch, pdf
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: "Single"
            case .batch: "Batch · CSV"
            case .pdf: "PDF labels"
            }
        }
    }

    var jobKind: Kind { kind ?? (wasBatch ? .batch : .single) }
}

/// Everything printed, newest first. Keeps the last `limit` jobs.
@MainActor
final class PrintHistory: ObservableObject {
    @Published private(set) var records: [PrintRecord]
    private let file: JSONFile<[PrintRecord]>
    static let limit = 200

    init(directory: URL = AppStorageLocation.directory) {
        file = JSONFile(url: directory.appendingPathComponent("history.json"))
        records = file.load() ?? []
    }

    func add(_ record: PrintRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        file.save(records)
    }

    func clear() {
        records = []
        file.save(records)
    }

    func delete(_ id: PrintRecord.ID) {
        records.removeAll { $0.id == id }
        file.save(records)
    }

    /// Labels printed successfully in the last 7 days (including today).
    var labelsPrintedThisWeek: Int {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? .distantPast
        return records.filter { $0.result == .printed && $0.date >= start }.map(\.labels).reduce(0, +)
    }

    var labelsPrintedTotal: Int { records.filter { $0.result == .printed }.map(\.labels).reduce(0, +) }

    /// Labels printed successfully since midnight.
    var labelsPrintedToday: Int {
        records.filter { $0.result == .printed && Calendar.current.isDateInToday($0.date) }.map(\.labels).reduce(0, +)
    }
}

// MARK: - Notifications

struct AppNotice: Identifiable, Hashable {
    enum Kind { case success, info, warning, problem }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let title: String
    let detail: String
}

/// What a notification is about; Settings › General can turn topics off.
enum NoticeTopic: String, CaseIterable {
    case prints, printer, general

    /// UserDefaults key for the on/off switch (default on).
    var settingKey: String { "notify.\(rawValue)" }
}

/// In-app notifications shown under the bell (this session only).
@MainActor
final class NoticeCenter: ObservableObject {
    @Published private(set) var notices: [AppNotice] = []
    @Published private(set) var unread = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isEnabled(_ topic: NoticeTopic) -> Bool { defaults.object(forKey: topic.settingKey) as? Bool ?? true }

    func post(_ kind: AppNotice.Kind, _ title: String, _ detail: String = "", topic: NoticeTopic = .general) {
        guard isEnabled(topic) else { return }
        notices.insert(AppNotice(kind: kind, title: title, detail: detail), at: 0)
        if notices.count > 30 { notices.removeLast(notices.count - 30) }
        unread += 1
    }

    func markAllRead() { unread = 0 }
    func clear() { notices = []; unread = 0 }
}
