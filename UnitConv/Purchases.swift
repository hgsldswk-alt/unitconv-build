import Combine
import Foundation
import StoreKit

@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var entitlement = Entitlement(firstOpen: .now)
    @Published private(set) var ready = false
    @Published private(set) var pro: Product?
    @Published private(set) var trial: Product?
    @Published private(set) var busy = false
    @Published private(set) var trialClaimed = false
    @Published private(set) var clock = Date()
    @Published var message: String?

    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?
    private var started = false
    private let proID = Bundle.main.object(forInfoDictionaryKey: "UnitConvProProductID") as? String ?? "com.hgsldswk.unitconv.pro"
    private let trialID = Bundle.main.object(forInfoDictionaryKey: "UnitConvTrialProductID") as? String ?? "com.hgsldswk.unitconv.trial"

    init(defaults: UserDefaults) { self.defaults = defaults }

    var hasPro: Bool { ready && entitlement.hasPro(at: .now) }
    var daysRemaining: Int {
        min(30, max(0, Int(ceil(entitlement.trialEnd.timeIntervalSince(clock) / 86_400))))
    }

    func start() async {
        guard !started else { return }
        started = true
        let now = Date()
        let firstOpen = defaults.object(forKey: "firstOpen") as? Date ?? now
        defaults.set(firstOpen, forKey: "firstOpen")
        entitlement.firstOpen = firstOpen
        if Launch.isTesting {
            entitlement.proStartedAt = Launch.testFlag("-expired") ? .distantPast : firstOpen
            entitlement.purchasedPro = defaults.bool(forKey: "purchasedPro")
            ready = true
            return
        }
        if Launch.isFree { ready = true; return }
        let proposed = defaults.object(forKey: "proStartedAt") as? Date ?? now
        defaults.set(proposed, forKey: "proStartedAt")
        let start = await Task.detached(priority: .utility) { TrialClock.start(proposed: proposed) }.value
        entitlement.proStartedAt = start
        defaults.set(start, forKey: "proStartedAt")
        entitlement.purchasedPro = defaults.bool(forKey: "purchasedPro")
        ready = true

        listener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update,
                   transaction.productID == self.proID || transaction.productID == self.trialID {
                    self.apply(transaction)
                    await transaction.finish()
                } else if case .unverified(let transaction, _) = update, transaction.productID == self.proID {
                    self.setEvidence(false)
                }
            }
        }
        await refresh()
    }

    func refresh() async {
        clock = .now
        guard ready, !Launch.isTesting, !Launch.isFree else { return }
        if let result = await StoreKit.Transaction.latest(for: proID) {
            switch result {
            case .verified(let transaction): apply(transaction)
            case .unverified: setEvidence(false)
            }
        }
        if let result = await StoreKit.Transaction.latest(for: trialID), case .verified(let transaction) = result {
            apply(transaction)
        }
    }

    func loadProducts() async {
        guard !Launch.isTesting, !Launch.isFree else { return }
        do {
            let products = try await Product.products(for: [proID, trialID])
            pro = products.first { $0.id == proID }
            trial = products.first { $0.id == trialID }
        } catch {
            self.message = L.t("paywall.unavailable")
        }
    }

    func buy(isTrial: Bool) async {
        guard !busy, !Launch.isFree, !Launch.isTesting else { return }
        guard let product = isTrial ? trial : pro else {
            self.message = L.t("paywall.unavailable")
            return
        }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    self.message = L.t("paywall.failed")
                    return
                }
                apply(transaction)
                await transaction.finish()
            case .pending: self.message = L.t("paywall.pending")
            case .userCancelled: break
            @unknown default: self.message = L.t("paywall.failed")
            }
        } catch {
            self.message = L.t("paywall.failed")
        }
    }

    func restore() async {
        guard !busy, !Launch.isFree else { return }
        busy = true
        defer { busy = false }
        if Launch.isTesting {
            if Launch.testFlag("-restore-pro") { setEvidence(true) }
            self.message = L.t(entitlement.purchasedPro ? "paywall.restored" : "paywall.none")
            return
        }
        do {
            try await AppStore.sync()
            await refresh()
            self.message = L.t(entitlement.purchasedPro ? "paywall.restored" : "paywall.none")
        } catch {
            self.message = L.t("paywall.failed")
        }
    }

    private func apply(_ transaction: StoreKit.Transaction) {
        if transaction.productID == proID { setEvidence(transaction.revocationDate == nil) }
        if transaction.productID == trialID { trialClaimed = transaction.revocationDate == nil }
    }

    private func setEvidence(_ evidence: Bool) {
        entitlement.applyPurchaseEvidence(evidence)
        defaults.set(evidence, forKey: "purchasedPro")
    }
}
