import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let unitPreset = UTType(exportedAs: "com.hgsldswk.unitconv.preset", conformingTo: .json)
}

@main
@MainActor
struct UnitConvApp: App {
    @StateObject private var model: AppModel
    @StateObject private var purchases: Purchases

    init() {
        let suite = "com.hgsldswk.unitconv.ui-testing"
        let defaults = Launch.isTesting ? (UserDefaults(suiteName: suite) ?? .standard) : .standard
        let root = URL.applicationSupportDirectory
        let file = root.appendingPathComponent(Launch.isTesting ? "ui-testing/presets.json" : "presets.json")
        if Launch.testFlag("-reset") {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        _model = StateObject(wrappedValue: AppModel(defaults: defaults, libraryURL: file))
        _purchases = StateObject(wrappedValue: Purchases(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(model: model, purchases: purchases)
                .preferredColorScheme(.light)
                .tint(Design.green)
                .task { await model.start() }
                .task { await purchases.start() }
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await model.openFile(url) }
                }
                .task {
                    if Launch.testFlag("-import-fixture") {
                        await openImportFixture()
                    }
                }
        }
    }

    private func openImportFixture() async {
        let code = ProcessInfo.processInfo.environment["UNITCONV_PRESET"] ?? ""
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".unitpreset")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let payload = try PresetPayload.decode(code: code)
            try payload.encoded().write(to: file, options: .atomic)
            await model.openFile(file)
        } catch {
            model.message = L.t("import.invalid")
        }
    }
}
