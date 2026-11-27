import Foundation

struct Entitlement: Equatable {
    static let duration: TimeInterval = 30 * 86_400

    var firstOpen: Date
    var proStartedAt: Date?
    var purchasedPro = false

    var trialStart: Date { proStartedAt ?? firstOpen }
    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    mutating func applyPurchaseEvidence(_ evidence: Bool?) {
        if let evidence { purchasedPro = evidence }
    }
}
