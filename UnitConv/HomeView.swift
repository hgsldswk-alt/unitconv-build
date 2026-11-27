import StoreKit
import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
    @Environment(\.scenePhase) private var scene
    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 63.0
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: focused ? 8 : 18) {
                    header
                    categories
                    inputCard
                    results
                }
                .padding(.horizontal, 23)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .background(Design.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if model.selection.dimension == .temperature {
                        Button { model.toggleSign() } label: { Text("±") }
                            .accessibilityLabel(L.t("input.sign"))
                            .accessibilityIdentifier("input.sign")
                    }
                    Spacer()
                    Button(L.t("common.done")) { focused = false }
                        .accessibilityIdentifier("input.done")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: Binding(
                get: { model.panel != nil },
                set: { if !$0 { model.panel = nil } }
            )) {
                PanelHost(model: model, purchases: purchases)
            }
            .alert(L.t("common.notice"), isPresented: noticeBinding) {
                Button(L.t("common.ok"), role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
            .onChange(of: scene, initial: true) { _, phase in
                if phase == .active { Task { await purchases.refresh() } }
            }
            .onChange(of: focused) { _, value in if !value { model.finishConversion() } }
            .reviewAfterCoreAction(when: reviewContext && model.result != nil && model.issue == nil && model.message == nil && !reviewExpiryToday) { requestReview() }
            .task(id: reviewContext) {
                guard scene == .active && !focused && model.panel == nil && purchases.ready else { return }
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, scene == .active, !focused, model.panel == nil else { return }
                let entitlement = purchases.entitlement
                let expiry = Launch.isFree || entitlement.purchasedPro ? nil : entitlement.trialEnd
                if CoreReview.shared.attempt(ifEligible: { model.qualifiesForSharedReview(expires: expiry) }, { requestReview() }) {
                    model.markSharedReviewRequested()
                }
            }
        }
        .foregroundStyle(Design.ink)
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { model.message != nil && model.panel == nil },
                set: { if !$0 { model.message = nil } })
    }

    private var reviewContext: Bool { scene == .active && !focused && model.panel == nil && purchases.ready }

    private var reviewExpiryToday: Bool {
        let entitlement = purchases.entitlement
        return !Launch.isFree && !entitlement.purchasedPro && Calendar.current.isDateInToday(entitlement.trialEnd)
    }

    private var header: some View {
        HStack {
            Text(L.t("app.name"))
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                focused = false
                model.panel = .combinations
            } label: {
                Label(L.t("home.presets"), systemImage: "chevron.down")
                    .labelStyle(TrailingIconLabel())
            }
            .buttonStyle(ActionStyle())
            .accessibilityIdentifier("home.presets")
        }
        .frame(minHeight: focused ? 44 : 50)
    }

    private var categories: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3),
                                 count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 3) {
            ForEach(model.session.order) { dimension in
                let selected = model.session.dimension == dimension
                Button {
                    model.choose(dimension, useShortcut: true)
                    focused = true
                } label: {
                    Text(dimension.title)
                        .font(.subheadline.weight(.semibold))
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selected ? Color.white : Design.subtle)
                        .background(selected ? Design.green : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("group." + dimension.id)
            }
        }
        .padding(3)
        .cardSurface(14)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: focused ? 4 : 9) {
            Text(model.currentPreset?.name ?? L.t("input.label"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.subtle)
            HStack(spacing: 8) {
                TextField(L.t("input.placeholder"), text: Binding(get: { model.input }, set: model.setInput))
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .font(.system(size: focused ? min(numberSize, 48) : numberSize, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel(L.t("input.label"))
                    .accessibilityIdentifier("input.number")
                Menu {
                    ForEach(model.selection.dimension.units) { unit in
                        Button {
                            model.changeSource(unit)
                            focused = true
                        } label: {
                            if unit == model.selection.source {
                                Label(unit.title + " · " + unit.symbol, systemImage: "checkmark")
                            } else {
                                Text(unit.title + " · " + unit.symbol)
                            }
                        }
                        .accessibilityIdentifier("source." + unit.id)
                    }
                } label: {
                    Label(model.selection.source.symbol, systemImage: "chevron.down")
                        .labelStyle(TrailingIconLabel())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.green)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(Design.tint, in: RoundedRectangle(cornerRadius: 13))
                }
                .accessibilityLabel(L.f("input.source", model.selection.source.title))
                .accessibilityIdentifier("input.source")
            }
            if let issue = model.issue, issue != .incomplete {
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("input.error")
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, focused ? 8 : 17)
        .cardSurface(22)
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Design.green, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: focused ? 4 : 7) {
            Text(L.t("home.results"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.subtle)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.selection.targets) { unit in
                let reading = model.result?.targets.first { $0.unit == unit }
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 5) {
                            if !unit.symbol.hasPrefix("US ") {
                                Text(unit.symbol).foregroundStyle(Design.green).fontWeight(.semibold)
                            }
                            Text(unit.title).foregroundStyle(Design.subtle)
                        }
                        Text(unit.title).foregroundStyle(Design.subtle)
                    }
                    .font(.footnote)
                    Spacer(minLength: 0)
                    Text(reading?.number ?? "—")
                        .font((focused ? Font.title3 : .title2).weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                        .layoutPriority(1)
                        .accessibilityIdentifier("result." + unit.id)
                    Button {
                        if let reading { copy(reading.text) }
                    } label: {
                        Text(L.t("common.copy"))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 5)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(Design.green)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(reading == nil)
                    .opacity(reading == nil ? 0.45 : 1)
                    .accessibilityLabel(L.f("home.copyUnit", unit.title))
                    .accessibilityIdentifier("copy." + unit.id)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: focused ? 44 : 60)
                .cardSurface(14)
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 4) {
            if let feedback {
                Text(feedback).font(.footnote).foregroundStyle(Design.green)
                    .accessibilityIdentifier("copy.feedback")
            }
            HStack(spacing: 8) {
                Button {
                    if let result = model.result { copy(result.text) }
                } label: { Text(L.t("home.copy")).frame(maxWidth: .infinity) }
                    .buttonStyle(ActionStyle(primary: true))
                    .accessibilityIdentifier("home.copy")
                Button {
                    focused = false
                    model.panel = .share
                } label: { Text(L.t("home.share")).frame(maxWidth: .infinity) }
                    .buttonStyle(ActionStyle())
                    .accessibilityIdentifier("home.share")
            }
            .disabled(model.result == nil)
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 6)
        .background(Design.paper)
    }

    private func copy(_ text: String) {
        model.copy(text)
        feedbackTask?.cancel()
        feedback = L.t("common.copied")
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { feedback = nil }
        }
    }
}

private struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.caption2.weight(.bold))
        }
    }
}
