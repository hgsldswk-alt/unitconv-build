import SwiftUI
import UniformTypeIdentifiers

struct PanelHost: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        NavigationStack {
            Group {
                switch model.panel {
                case .combinations: CombinationsView(model: model, purchases: purchases)
                case .settings: SettingsView(model: model, purchases: purchases)
                case .editor: PresetEditor(model: model, purchases: purchases)
                case .shortcuts: ShortcutsView(model: model, purchases: purchases)
                case .importPreview: ImportPreview(model: model)
                case .share, .milestone: ShareView(model: model, startsOnMilestone: model.panel == .milestone)
                case .paywall: PaywallView(model: model, purchases: purchases)
                case nil: Color.clear
                }
            }
            .id(model.panel)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { model.panel = nil }
                        .disabled(model.saving || purchases.busy)
                        .accessibilityIdentifier("panel.close")
                }
            }
            .alert(L.t("common.notice"), isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )) {
                Button(L.t("common.ok"), role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
            .interactiveDismissDisabled(model.saving || purchases.busy)
        }
    }
}

private struct CombinationsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
    @State private var pickingFile = false

    var body: some View {
        List {
            Section(L.t("preset.builtIn")) {
                ForEach(Dimension.allCases) { dimension in
                    Button {
                        model.basic(dimension)
                        model.panel = nil
                    } label: {
                        let selection = Selection.basic(dimension.units[0])
                        PresetLabel(name: dimension.title, selection: selection)
                    }
                    .accessibilityIdentifier("preset.basic." + dimension.id)
                }
            }
            Section(L.t("preset.saved")) {
                ForEach(model.library.entries) { preset in
                    HStack {
                        Button {
                            model.choose(preset)
                            model.panel = nil
                        } label: { PresetLabel(name: preset.name, selection: preset.selection) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("preset.use." + preset.name)
                        Spacer()
                        Button(L.t("common.edit")) { openEditor(preset) }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                            .disabled(!purchases.ready)
                            .accessibilityIdentifier("preset.edit." + preset.name)
                    }
                }
                Button(L.t("preset.create")) { openEditor(nil) }
                    .disabled(!model.libraryReady || !purchases.ready)
                    .accessibilityIdentifier("preset.new")
                Button(L.t("shortcut.title")) {
                    model.panel = purchases.hasPro ? .shortcuts : .paywall
                }
                .disabled(!model.libraryReady || !purchases.ready)
                .accessibilityIdentifier("preset.shortcuts")
            }
            Section(L.t("import.title")) {
                PasteButton(payloadType: String.self) { items in
                    if let code = items.first { model.readCode(code) }
                }
                .labelStyle(.titleOnly)
                .accessibilityLabel(L.t("import.paste"))
                .accessibilityIdentifier("import.paste")
                Button(L.t("import.file")) { pickingFile = true }
                    .accessibilityIdentifier("import.file")
            }
            Section {
                Button(L.t("settings.title")) { model.panel = .settings }
                    .accessibilityIdentifier("preset.settings")
            }
        }
        .navigationTitle(L.t("home.presets"))
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.unitPreset]) { result in
            switch result {
            case .success(let url): Task { await model.openFile(url) }
            case .failure: model.message = L.t("import.invalid")
            }
        }
    }

    private func openEditor(_ preset: Preset?) {
        model.editing = preset
        model.panel = purchases.hasPro ? .editor : .paywall
    }
}

struct PresetLabel: View {
    let name: String
    let selection: Selection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.body.weight(.semibold)).foregroundStyle(Design.ink)
            Text(selection.source.symbol + " → " + selection.targets.map(\.symbol).joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Design.subtle)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ImportPreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            if let payload = model.incoming {
                PresetLabel(name: payload.name, selection: payload.selection)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("import.preview")
                Button(L.t("import.confirm")) {
                    Task {
                        if await model.confirmImport() { model.panel = nil }
                    }
                }
                .disabled(!model.libraryReady || model.saving)
                .accessibilityIdentifier("import.confirm")
                Button(L.t("common.cancel")) { model.panel = .combinations }
                    .disabled(model.saving)
                    .accessibilityIdentifier("import.cancel")
            }
        }
        .navigationTitle(L.t("import.previewTitle"))
    }
}

private struct PresetEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
    @State private var name: String
    @State private var dimension: Dimension
    @State private var source: MeasureUnit
    @State private var targets: [MeasureUnit]

    init(model: AppModel, purchases: Purchases) {
        self.model = model
        self.purchases = purchases
        let selection = model.editing?.selection ?? model.selection
        _name = State(initialValue: model.editing?.name ?? selection.dimension.title)
        _dimension = State(initialValue: selection.dimension)
        _source = State(initialValue: selection.source)
        _targets = State(initialValue: selection.targets)
    }

    var body: some View {
        Form {
            TextField(L.t("preset.name"), text: $name)
                .accessibilityIdentifier("editor.name")
            Picker(L.t("preset.dimension"), selection: $dimension) {
                ForEach(Dimension.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("editor.dimension")
            Picker(L.t("preset.source"), selection: $source) {
                ForEach(dimension.units) { Text($0.title + " · " + $0.symbol).tag($0) }
            }
            .accessibilityIdentifier("editor.source")
            Section(L.t("preset.targets")) {
                ForEach(dimension.units.filter { $0 != source }) { unit in
                    Button {
                        if let index = targets.firstIndex(of: unit) { targets.remove(at: index) }
                        else if targets.count < 3 { targets.append(unit) }
                    } label: {
                        HStack {
                            Text(unit.title + " · " + unit.symbol)
                            Spacer()
                            if let index = targets.firstIndex(of: unit) {
                                Text((index + 1).formatted()).monospacedDigit()
                            }
                        }
                    }
                    .disabled(!targets.contains(unit) && targets.count >= 3)
                    .accessibilityAddTraits(targets.contains(unit) ? .isSelected : [])
                    .accessibilityIdentifier("editor.target." + unit.id)
                }
            }
            Button(L.t("common.save")) { save() }
                .disabled(!valid || model.saving)
                .accessibilityIdentifier("editor.save")
        }
        .navigationTitle(L.t(model.editing == nil ? "preset.create" : "preset.editTitle"))
        .onChange(of: dimension) { _, next in source = next.units[0] }
        .onChange(of: source) { _, next in targets = Selection.basic(next).targets }
    }

    private var preset: Preset {
        Preset(id: model.editing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
               selection: Selection(source: source, targets: targets))
    }

    private var valid: Bool { (try? preset.payload.validate()) != nil }

    private func save() {
        guard purchases.hasPro else { model.panel = .paywall; return }
        let value = preset
        Task {
            if await model.savePreset(value), model.panel == .editor { model.panel = nil }
        }
    }
}

private struct ShortcutsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        Form {
            ForEach(model.session.order) { dimension in
                Section(dimension.title) {
                    Picker(L.t("shortcut.choice"), selection: Binding(
                        get: { model.session.shortcuts[dimension.id] },
                        set: { id in
                            if purchases.hasPro { model.setShortcut(id, for: dimension) }
                            else { model.panel = .paywall }
                        }
                    )) {
                        Text(L.t("shortcut.last")).tag(nil as UUID?)
                        ForEach(model.library.entries.filter { $0.selection.dimension == dimension }) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .accessibilityIdentifier("shortcut.picker." + dimension.id)
                    HStack {
                        move(dimension, direction: -1)
                        Spacer()
                        move(dimension, direction: 1)
                    }
                }
            }
        }
        .navigationTitle(L.t("shortcut.title"))
    }

    private func move(_ dimension: Dimension, direction: Int) -> some View {
        let index = model.session.order.firstIndex(of: dimension) ?? 0
        let destination = index + direction
        return Button(L.t(direction < 0 ? "shortcut.up" : "shortcut.down")) {
            guard purchases.hasPro else { model.panel = .paywall; return }
            model.moveShortcut(from: IndexSet(integer: index), to: direction < 0 ? destination : destination + 1)
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
        .disabled(!model.session.order.indices.contains(destination))
        .accessibilityIdentifier("shortcut." + dimension.id + (direction < 0 ? ".up" : ".down"))
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        List {
            if !Launch.isFree {
                Section(L.t("paywall.title")) {
                    Text(purchases.entitlement.purchasedPro ? L.t("paywall.owned") :
                         (purchases.hasPro ? L.f("paywall.days", purchases.daysRemaining) : L.t("paywall.expired")))
                        .accessibilityIdentifier("settings.entitlement")
                    Button(L.t("paywall.manage")) { model.panel = .paywall }
                        .accessibilityIdentifier("settings.paywall")
                }
            }
            Section(L.t("settings.about")) {
                Text(L.t("settings.offline"))
                if model.stats.milestone {
                    Button(L.t("share.milestone")) { model.panel = .milestone }
                        .accessibilityIdentifier("settings.milestone")
                }
            }
        }
        .navigationTitle(L.t("settings.title"))
    }
}

private struct PaywallView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        List {
            Section {
                Text(L.t("paywall.title")).font(.title2.bold())
                    .accessibilityIdentifier("paywall.title")
                Text(L.t("paywall.features"))
                Text(L.t("paywall.keepsData"))
                if purchases.ready {
                    Text(purchases.entitlement.purchasedPro ? L.t("paywall.owned") :
                         (purchases.hasPro ? L.f("paywall.days", purchases.daysRemaining) : L.t("paywall.expired")))
                }
            }
            Section {
                if !purchases.entitlement.purchasedPro {
                    let price = purchases.pro?.displayPrice ?? (Launch.isTesting ? L.t("paywall.testPrice") : nil)
                    Button(price.map { L.f("paywall.buyPrice", $0) } ?? L.t("paywall.buy")) {
                        Task { await purchases.buy(isTrial: false) }
                    }
                    .disabled(purchases.busy || (price == nil && !Launch.isTesting))
                    .accessibilityIdentifier("paywall.buy")
                    if !purchases.trialClaimed && purchases.hasPro {
                        Button(L.t("paywall.trial")) { Task { await purchases.buy(isTrial: true) } }
                            .disabled(purchases.busy || (purchases.trial == nil && !Launch.isTesting))
                            .accessibilityIdentifier("paywall.trial")
                    }
                    if price == nil && !Launch.isTesting {
                        Button(L.t("paywall.retry")) { Task { await purchases.loadProducts() } }
                            .accessibilityIdentifier("paywall.retry")
                    }
                }
                Button(L.t("paywall.restore")) { Task { await purchases.restore() } }
                    .disabled(purchases.busy)
                    .accessibilityIdentifier("paywall.restore")
                if let message = purchases.message {
                    Text(message).font(.footnote).accessibilityIdentifier("paywall.message")
                }
            }
        }
        .navigationTitle(L.t("paywall.manage"))
        .task { await purchases.loadProducts() }
    }
}
