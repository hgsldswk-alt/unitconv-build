import CoreImage
import Foundation
import XCTest

final class CoreTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    func testExactRatiosAndReverse() throws {
        let ratios: [(MeasureUnit, MeasureUnit, String)] = [
            (.lb, .g, "453.59237"), (.oz, .g, "28.349523125"), (.kg, .g, "1000"),
            (.cup, .ml, "236.5882365"), (.flOz, .ml, "29.5735295625"),
            (.tbsp, .ml, "14.78676478125"), (.tbsp, .tsp, "3"),
            (.mph, .kmh, "1.609344"), (.ms, .kmh, "3.6")
        ]
        for (source, target, factor) in ratios {
            let expected = Conversion.decimal(factor)
            XCTAssertEqual(try Conversion.convert(1, from: source, to: target), expected, source.id)
            let reversed = try Conversion.convert(expected, from: target, to: source)
            XCTAssertLessThan(abs(reversed - 1), Conversion.decimal("0.000000000000000000000001"), source.id)
        }
        XCTAssertThrowsError(try Conversion.convert(1, from: .ml, to: .g))
        XCTAssertThrowsError(try Conversion.convert(-1, from: .lb, to: .g)) { XCTAssertEqual($0 as? ConversionIssue, .negative) }
        XCTAssertEqual(try Conversion.convert(0, from: .lb, to: .g), 0)
    }

    func testTemperatureBoundsAndOffsets() throws {
        let c = Conversion.decimal("-273.15"), f = Conversion.decimal("-459.67")
        XCTAssertEqual(try Conversion.convert(c, from: .celsius, to: .kelvin), 0)
        XCTAssertEqual(try Conversion.convert(f, from: .fahrenheit, to: .kelvin), 0)
        XCTAssertEqual(try Conversion.convert(0, from: .kelvin, to: .celsius), c)
        XCTAssertEqual(try Conversion.convert(0, from: .kelvin, to: .fahrenheit), f)
        XCTAssertEqual(try Conversion.convert(-40, from: .celsius, to: .fahrenheit), -40)
        let belowMinimum: [(MeasureUnit, String)] = [(.celsius, "-273.1501"), (.fahrenheit, "-459.6701"), (.kelvin, "-0.01")]
        for (source, input) in belowMinimum {
            XCTAssertThrowsError(try Conversion.convert(Conversion.decimal(input), from: source, to: .kelvin)) {
                XCTAssertEqual($0 as? ConversionIssue, .absoluteZero)
            }
        }
    }

    func testLocaleParsingAndFormatting() throws {
        XCTAssertEqual(try Conversion.parse("−１２，５", separator: ","), Conversion.decimal("-12.5"))
        XCTAssertEqual(try Conversion.parse(" .5 ", separator: "."), Conversion.decimal("0.5"))
        XCTAssertEqual(try Conversion.parse("١٢٫٥", separator: "٫"), Conversion.decimal("12.5"))
        XCTAssertEqual(try Conversion.parse("1" + String(repeating: "0", count: 40), separator: "."),
                       Conversion.decimal("1e40"))
        for invalid in ["1.234,5", "1 234", "2,5 g", "1e4", "1..2"] {
            XCTAssertThrowsError(try Conversion.parse(invalid, separator: ","), invalid)
        }
        XCTAssertThrowsError(try Conversion.parse("12,", separator: ",")) { XCTAssertEqual($0 as? ConversionIssue, .incomplete) }
        XCTAssertThrowsError(try Conversion.parse(String(repeating: "9", count: 39), separator: ".")) {
            XCTAssertEqual($0 as? ConversionIssue, .overflow)
        }
        XCTAssertEqual(Conversion.format(Conversion.decimal("1.23455"), locale: german), "1,2346")
        XCTAssertTrue(Conversion.format(Conversion.decimal("0.00001234567"), locale: english).contains("1.23457e"))
        XCTAssertTrue(Conversion.format(Conversion.decimal("1234567000"), locale: english).contains("1.23457e"))
        let weight = try Conversion.results("250", selection: .basic(.g), locale: english)
        XCTAssertEqual(weight.targets.map(\.number), ["0.25", "8.8185", "0.5512"])
        XCTAssertEqual(weight.text, "250 g\n0.25 kg\n8.8185 oz\n0.5512 lb")
        let speed = try Conversion.results("65", selection: .basic(.mph), locale: english)
        XCTAssertEqual(speed.targets, [Reading(unit: .ms, number: "29.0576"), Reading(unit: .kmh, number: "104.6074")])
        XCTAssertEqual(Selection.basic(.cup).targets, [.flOz, .tbsp, .ml])
    }

    func testPresetRoundTripAndDeduplication() throws {
        let original = Preset(name: "备料", selection: .basic(.ml)).payload
        let code = try original.code()
        XCTAssertTrue(code.hasPrefix("UC1:"))
        XCTAssertEqual(try PresetPayload.decode(code: code), original)
        XCTAssertEqual(try PresetPayload.decode(original.encoded()), original)
        var library = PresetLibrary()
        let first = try library.importPayload(original)
        let duplicate = try library.importPayload(Preset(name: "不同名称", selection: .basic(.ml)).payload)
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertThrowsError(try PresetPayload.decode(Data(repeating: 0, count: PresetPayload.limit + 1)))
        for data in [
            #"{"name":"坏","version":2,"dimension":"weight","source":"g","targets":["kg","oz"]}"#,
            #"{"name":"坏","version":1,"dimension":"volume","source":"g","targets":["kg","oz"]}"#,
            #"{"name":"坏","version":1,"dimension":"weight","source":"g","targets":["kg","kg"]}"#,
            #"{"name":"坏","version":1,"dimension":"weight","source":"g","targets":["kg","unknown"]}"#
        ] {
            XCTAssertThrowsError(try PresetPayload.decode(Data(data.utf8)))
        }
    }

    func testLibraryAtomicPersistenceAndFailure() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("presets.json")
        XCTAssertTrue(try PresetLibrary.load(from: url).entries.isEmpty)
        var library = PresetLibrary()
        _ = try library.importPayload(Preset(name: "Warehouse", selection: .basic(.lb)).payload)
        try library.save(to: url)
        XCTAssertEqual(try PresetLibrary.load(from: url).entries, library.entries)
        XCTAssertThrowsError(try library.save(to: url.appendingPathComponent("cannotWrite.json")))
        XCTAssertEqual(try PresetLibrary.load(from: url).entries, library.entries)
    }

    func testSessionDropsNumberWhenSourceOrDimensionChanges() throws {
        var session = LastSession()
        session.lastValidInput = "250"
        XCTAssertFalse(session.select(GroupSession(selection: Selection(source: .g, targets: [.oz, .lb]))))
        XCTAssertEqual(session.lastValidInput, "250")
        XCTAssertTrue(session.select(GroupSession(selection: .basic(.lb))))
        XCTAssertTrue(session.lastValidInput.isEmpty)
        XCTAssertTrue(session.select(GroupSession(selection: .basic(.ml))))
        XCTAssertEqual(session.groups[Dimension.weight.id]?.selection.source, .lb)
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(LastSession.self, from: data), session)
    }

    func testTrialUpgradeExpiryRestoreAndRevocation() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        let paid = first.addingTimeInterval(120 * 86_400)
        var entitlement = Entitlement(firstOpen: first, proStartedAt: paid)
        XCTAssertEqual(Entitlement(firstOpen: first).trialStart, first)
        XCTAssertTrue(entitlement.hasPro(at: paid.addingTimeInterval(29 * 86_400)))
        XCTAssertFalse(entitlement.hasPro(at: paid.addingTimeInterval(30 * 86_400)))
        XCTAssertFalse(entitlement.hasPro(at: first))
        XCTAssertTrue(entitlement.hasPro(at: first, free: true))
        entitlement.applyPurchaseEvidence(true)
        entitlement.applyPurchaseEvidence(nil)
        XCTAssertTrue(entitlement.hasPro(at: .distantFuture))
        entitlement.applyPurchaseEvidence(false)
        XCTAssertFalse(entitlement.hasPro(at: .distantFuture))
        XCTAssertEqual(entitlement.trialStart, paid)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testUsageMilestoneAndOneTimeReview() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var stats = UsageStats()
        for day in 0..<10 {
            let now = start.addingTimeInterval(TimeInterval(day * 86_400))
            stats.recordInput(on: now, calendar: calendar)
            stats.recordInput(on: now, calendar: calendar)
            XCTAssertEqual(stats.days.count, day + 1)
            XCTAssertEqual(stats.milestone, day >= 6)
        }
        XCTAssertFalse(stats.canRequestReview(now: start, expires: nil, calendar: calendar))
        stats.recordAction()
        stats.recordAction()
        XCTAssertFalse(stats.canRequestReview(now: start, expires: start, calendar: calendar))
        XCTAssertTrue(stats.canRequestReview(now: start, expires: nil, calendar: calendar))
        stats.markReviewRequested()
        XCTAssertFalse(stats.canRequestReview(now: start, expires: nil, calendar: calendar))
    }

    func testQRCodeReadBackWithCoreImage() throws {
        XCTAssertNil(ShareAssets.storeURL(id: ""))
        XCTAssertNil(ShareAssets.storeURL(id: "__APP_STORE_ID__"))
        let url = try XCTUnwrap(ShareAssets.storeURL(id: "1234567890"))
        XCTAssertEqual(url.absoluteString, "https://apps.apple.com/app/id1234567890")
        let image = try XCTUnwrap(ShareAssets.qr(for: url))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)
        XCTAssertEqual(feature.messageString, url.absoluteString)
    }
}
