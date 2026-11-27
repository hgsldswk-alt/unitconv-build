import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Panel: String, Identifiable {
        case combinations, settings, editor, shortcuts, importPreview, share, milestone, paywall
        var id: String { rawValue }
    }

    static let locale = Locale.current
    static var separator: String { locale.decimalSeparator ?? "." }

    @Published private(set) var library = PresetLibrary()
    @Published private(set) var libraryReady = false
    @Published private(set) var saving = false
    @Published private(set) var session = LastSession()
    @Published private(set) var stats = UsageStats()
    @Published private(set) var input = ""
    @Published private(set) var result: ResultSet?
    @Published private(set) var issue: ConversionIssue?
    @Published var panel: Panel?
    @Published var message: String?
    @Published var editing: Preset?
    @Published private(set) var incoming: PresetPayload?

    let defaults: UserDefaults
    let libraryURL: URL
    private var started = false
    private var skipReviewAfterImport = false
    private var editedConversion = false

    init(defaults: UserDefaults, libraryURL: URL) {
        self.defaults = defaults
        self.libraryURL = libraryURL
        if let saved = Self.read(LastSession.self, key: "session", defaults: defaults) { session = saved }
        if Set(session.order) != Set(Dimension.allCases) || session.order.count != Dimension.allCases.count {
            session.order = Dimension.allCases
        }
        stats = Self.read(UsageStats.self, key: "stats", defaults: defaults) ?? UsageStats()
        if session.decimalSeparator != Self.separator {
            session.lastValidInput = session.lastValidInput.replacingOccurrences(of: session.decimalSeparator, with: Self.separator)
        }
        if let seed = Launch.value("-usage-days").flatMap(Int.init) {
            for offset in 0..<min(30, max(0, seed)) {
                if let day = Calendar.current.date(byAdding: .day, value: -offset, to: .now) {
                    stats.recordInput(on: day)
                }
            }
        }
        input = session.lastValidInput
        if Launch.isTesting, let group = Launch.value("-group").flatMap(Dimension.init(rawValue:)) {
            let source = Launch.value("-source").flatMap(MeasureUnit.init(rawValue:)) ?? group.units[0]
            _ = session.select(GroupSession(selection: .basic(source)))
            input = ""
        }
        if Launch.isTesting, let value = ProcessInfo.processInfo.environment["UNITCONV_INPUT"] {
            input = value.replacingOccurrences(of: ".", with: Self.separator)
        }
        calculate()
        saveSession()
        if Launch.testFlag("-paywall") { panel = .paywall }
    }

    var selection: Selection { session.group.selection }

    var currentPreset: Preset? {
        library.entries.first { $0.id == session.group.presetID }
    }

    var sharePayload: PresetPayload {
        Preset(name: currentPreset?.name ?? selection.dimension.title, selection: selection).payload
    }

    static func read<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let bytes = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }

    func start() async {
        guard !started else { return }
        started = true
        let url = libraryURL
        do {
            library = try await Task.detached(priority: .utility) { try PresetLibrary.load(from: url) }.value
            libraryReady = true
        } catch {
            self.message = L.t("preset.readError")
        }
    }

    func setInput(_ value: String) {
        guard input != value else { return }
        input = value
        calculate()
        editedConversion = result != nil
        if result != nil {
            stats.recordInput(on: .now)
            saveStats()
        }
        saveSession()
    }

    func finishConversion() {
        guard editedConversion else { return }
        editedConversion = false
        if result != nil { CoreReview.shared.record() }
    }

    func toggleSign() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .replacingOccurrences(of: "−", with: "-") ?? input
        if trimmed.hasPrefix("-") { setInput(String(trimmed.dropFirst())) }
        else { setInput("-" + (trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed)) }
    }

    func choose(_ dimension: Dimension, useShortcut: Bool) {
        if useShortcut,
           let shortcut = library.entries.first(where: { $0.id == session.shortcuts[dimension.id] && $0.selection.dimension == dimension }) {
            choose(shortcut)
        } else if let saved = session.groups[dimension.id], saved.selection.dimension == dimension,
                  (try? saved.selection.validate()) != nil {
            select(saved)
        } else {
            basic(dimension)
        }
    }

    func changeSource(_ source: MeasureUnit) {
        guard source != selection.source, source.dimension == selection.dimension else { return }
        select(GroupSession(selection: .basic(source)))
    }

    func choose(_ preset: Preset) {
        select(GroupSession(selection: preset.selection, presetID: preset.id))
    }

    func basic(_ dimension: Dimension) {
        select(GroupSession(selection: .basic(dimension.units[0])))
    }

    private func select(_ group: GroupSession) {
        if session.select(group) { input = "" }
        calculate()
        saveSession()
    }

    func setShortcut(_ id: UUID?, for dimension: Dimension) {
        session.shortcuts[dimension.id] = id
        saveSession()
    }

    func moveShortcut(from offsets: IndexSet, to index: Int) {
        session.order.move(fromOffsets: offsets, toOffset: index)
        saveSession()
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        recordAction()
    }

    func recordAction() {
        stats.recordAction()
        saveStats()
    }

    func qualifiesForSharedReview(expires: Date?) -> Bool {
        if skipReviewAfterImport {
            skipReviewAfterImport = false
            return false
        }
        guard !Launch.isTesting, panel == nil, issue == nil, message == nil,
              stats.canRequestReview(now: .now, expires: expires) else { return false }
        return true
    }

    func markSharedReviewRequested() {
        stats.markReviewRequested()
        saveStats()
    }

    func readCode(_ text: String) {
        do { preview(try PresetPayload.decode(code: text)) }
        catch { showImportError(error) }
    }

    func openFile(_ url: URL) async {
        do {
            let payload = try await Task.detached(priority: .utility) { try PresetPayload.read(file: url) }.value
            preview(payload)
        } catch {
            showImportError(error)
        }
    }

    private func preview(_ payload: PresetPayload) {
        skipReviewAfterImport = true
        incoming = payload
        panel = .importPreview
    }

    private func showImportError(_ error: Error) {
        switch error as? PresetIssue {
        case .version: self.message = L.t("import.version")
        case .size: self.message = L.t("import.size")
        default: self.message = L.t("import.invalid")
        }
    }

    func confirmImport() async -> Bool {
        guard let incoming, libraryReady, !saving else { return false }
        var updated = library
        do {
            let preset = try updated.importPayload(incoming)
            if library.entries != updated.entries {
                guard await persist(updated) else { return false }
            }
            choose(preset)
            guard self.incoming == incoming else { return false }
            self.incoming = nil
            return true
        } catch {
            showImportError(error)
            return false
        }
    }

    func savePreset(_ preset: Preset) async -> Bool {
        guard libraryReady, !saving else { return false }
        do {
            _ = try preset.payload.encoded()
        } catch {
            self.message = L.t("preset.invalid")
            return false
        }
        var updated = library
        if let index = updated.entries.firstIndex(where: { $0.id == preset.id }) {
            updated.entries[index] = preset
        } else {
            updated.entries.append(preset)
        }
        guard await persist(updated) else { return false }
        for dimension in Dimension.allCases where dimension != preset.selection.dimension {
            if session.shortcuts[dimension.id] == preset.id { session.shortcuts[dimension.id] = nil }
            if session.groups[dimension.id]?.presetID == preset.id { session.groups[dimension.id]?.presetID = nil }
        }
        choose(preset)
        return true
    }

    private func persist(_ updated: PresetLibrary) async -> Bool {
        saving = true
        defer { saving = false }
        let url = libraryURL
        do {
            try await Task.detached(priority: .utility) { try updated.save(to: url) }.value
            library = updated
            return true
        } catch {
            self.message = L.t("preset.writeError")
            return false
        }
    }

    private func calculate() {
        do {
            result = try Conversion.results(input, selection: selection, locale: Self.locale)
            issue = nil
            session.lastValidInput = input
        } catch {
            result = nil
            issue = input.isEmpty ? nil : error as? ConversionIssue ?? .invalid
            session.lastValidInput = ""
        }
    }

    private func saveStats() {
        if let data = try? JSONEncoder().encode(stats) { defaults.set(data, forKey: "stats") }
    }

    private func saveSession() {
        session.decimalSeparator = Self.separator
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: "session") }
    }
}
