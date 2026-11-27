import Foundation

struct Selection: Codable, Equatable {
    let source: MeasureUnit
    let targets: [MeasureUnit]
    var dimension: Dimension { source.dimension }

    init(source: MeasureUnit, targets: [MeasureUnit]) {
        self.source = source
        self.targets = targets
    }

    static func basic(_ source: MeasureUnit) -> Self {
        let units = source.dimension.units
        let defaultTargets = units.dropFirst().prefix(3)
        let candidates = Array(defaultTargets) + [units[0]] + Array(units.dropFirst(4))
        return Selection(source: source, targets: Array(candidates.filter { $0 != source }.prefix(3)))
    }

    func validate() throws {
        guard (2...3).contains(targets.count), Set(targets).count == targets.count,
              targets.allSatisfy({ $0.dimension == dimension && $0 != source })
        else { throw PresetIssue.invalid }
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    let selection: Selection

    var payload: PresetPayload {
        PresetPayload(version: 1, name: name, dimension: selection.dimension,
                      source: selection.source, targets: selection.targets)
    }
}

enum PresetIssue: Error { case invalid, version, size }

struct PresetPayload: Codable, Equatable {
    static let limit = 8 * 1024
    let version: Int
    let name: String
    let dimension: Dimension
    let source: MeasureUnit
    let targets: [MeasureUnit]

    var selection: Selection { Selection(source: source, targets: targets) }

    func validate() throws {
        guard version == 1 else { throw PresetIssue.version }
        guard source.dimension == dimension, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...60).contains(name.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw PresetIssue.invalid }
        try selection.validate()
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.limit else { throw PresetIssue.size }
        return data
    }

    func code() throws -> String {
        "UC1:" + (try encoded()).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= limit else { throw PresetIssue.size }
        let payload = try JSONDecoder().decode(Self.self, from: data)
        try payload.validate()
        return payload
    }

    static func decode(code: String) throws -> Self {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("UC1:") else { throw PresetIssue.invalid }
        let encoded = String(code.dropFirst(4))
        guard encoded.utf8.count <= (limit * 4 + 2) / 3 else { throw PresetIssue.size }
        guard encoded.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw PresetIssue.invalid }
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64) else { throw PresetIssue.invalid }
        return try decode(data)
    }

    static func read(file url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: limit + 1) ?? Data())
    }
}

struct PresetLibrary: Codable {
    var version = 1
    var entries: [Preset] = []

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
        let library = try JSONDecoder().decode(Self.self, from: data)
        guard library.version == 1 else { throw PresetIssue.version }
        guard Set(library.entries.map(\.id)).count == library.entries.count else { throw PresetIssue.invalid }
        for entry in library.entries { try entry.payload.validate() }
        return library
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func importPayload(_ payload: PresetPayload) throws -> Preset {
        try payload.validate()
        if let existing = entries.first(where: { $0.selection == payload.selection }) { return existing }
        let preset = Preset(name: payload.name, selection: payload.selection)
        entries.append(preset)
        return preset
    }
}

struct GroupSession: Codable, Equatable {
    var selection: Selection
    var presetID: UUID?
}

struct LastSession: Codable, Equatable {
    var dimension = Dimension.weight
    var groups: [String: GroupSession] = [:]
    var shortcuts: [String: UUID] = [:]
    var order = Dimension.allCases
    var lastValidInput = ""
    var decimalSeparator = "."

    var group: GroupSession {
        if let current = groups[dimension.id], current.selection.dimension == dimension,
           (try? current.selection.validate()) != nil { return current }
        return GroupSession(selection: .basic(dimension.units[0]))
    }

    mutating func select(_ next: GroupSession) -> Bool {
        let changed = next.selection.dimension != dimension || next.selection.source != group.selection.source
        if changed { lastValidInput = "" }
        dimension = next.selection.dimension
        groups[dimension.id] = next
        return changed
    }
}

struct UsageStats: Codable {
    private(set) var days: Set<String> = []
    private(set) var activeActions = 0
    private(set) var reviewRequested = false

    var milestone: Bool { days.count >= 7 }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [parts.era, parts.year, parts.month, parts.day].map { String($0 ?? 0) }.joined(separator: ".")
    }

    mutating func recordInput(on date: Date, calendar: Calendar = .current) {
        days.insert(Self.dayKey(date, calendar: calendar))
    }

    mutating func recordAction() { if activeActions < Int.max { activeActions += 1 } }

    func canRequestReview(now: Date, expires: Date?, calendar: Calendar = .current) -> Bool {
        days.count >= 10 && activeActions >= 2 && !reviewRequested &&
            !(expires.map { calendar.isDate($0, inSameDayAs: now) } ?? false)
    }

    mutating func markReviewRequested() { reviewRequested = true }
}
