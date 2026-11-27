import Foundation

enum Dimension: String, Codable, CaseIterable, Identifiable {
    case weight, volume, temperature, speed

    var id: String { rawValue }
    var title: String { L.t("dimension." + rawValue) }

    var units: [MeasureUnit] {
        switch self {
        case .weight: [.g, .kg, .oz, .lb]
        case .volume: [.ml, .flOz, .cup, .tbsp, .liter, .tsp]
        case .temperature: [.celsius, .fahrenheit, .kelvin]
        case .speed: [.kmh, .mph, .ms]
        }
    }
}

enum MeasureUnit: String, Codable, CaseIterable, Identifiable {
    case g, kg, oz, lb, ml, liter, flOz, cup, tbsp, tsp, celsius, fahrenheit, kelvin, kmh, mph, ms

    var id: String { rawValue }
    var title: String { L.t("unit." + rawValue) }
    var symbol: String { L.t("symbol." + rawValue) }
    var dimension: Dimension { Dimension.allCases.first { $0.units.contains(self) }! }

    var ratio: (numerator: Decimal, denominator: Decimal) {
        switch self {
        case .g, .ml, .kmh: (1, 1)
        case .kg, .liter: (1000, 1)
        case .oz: (Conversion.decimal("28.349523125"), 1)
        case .lb: (Conversion.decimal("453.59237"), 1)
        case .flOz: (Conversion.decimal("29.5735295625"), 1)
        case .cup: (Conversion.decimal("236.5882365"), 1)
        case .tbsp: (Conversion.decimal("14.78676478125"), 1)
        case .tsp: (Conversion.decimal("14.78676478125"), 3)
        case .mph: (Conversion.decimal("1.609344"), 1)
        case .ms: (18, 5)
        case .celsius, .fahrenheit, .kelvin: (1, 1)
        }
    }

    var minimum: Decimal {
        switch self {
        case .celsius: Conversion.decimal("-273.15")
        case .fahrenheit: Conversion.decimal("-459.67")
        default: 0
        }
    }
}

enum ConversionIssue: String, Error {
    case incomplete, invalid, overflow, negative, absoluteZero
    var message: String { L.t("input." + rawValue) }
}

struct Reading: Identifiable, Equatable {
    let unit: MeasureUnit
    let number: String
    var id: String { unit.id }
    var text: String { "\(number) \(unit.symbol)" }
}

struct ResultSet: Equatable {
    let source: Reading
    let targets: [Reading]
    var text: String { ([source.text] + targets.map(\.text)).joined(separator: "\n") }
}

enum Conversion {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: posix)! }

    static func parse(_ text: String, separator: String) throws -> Decimal {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .replacingOccurrences(of: "−", with: "-") ?? text
        let canonical = String(input.replacingOccurrences(of: separator, with: ".").map { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first, CharacterSet.decimalDigits.contains(scalar),
                  let digit = character.wholeNumberValue, (0...9).contains(digit)
            else { return character }
            return Character(String(digit))
        })
        if canonical.isEmpty || canonical == "-" || canonical == "+" || canonical == "." || canonical == "-." || canonical == "+." {
            throw ConversionIssue.incomplete
        }
        guard (separator == "." || !input.contains(".")),
              canonical.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil
        else { throw ConversionIssue.invalid }
        if canonical.hasSuffix(".") { throw ConversionIssue.incomplete }

        let digits = canonical.filter { $0 != "+" && $0 != "-" }
        let fragments = digits.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = fragments.count > 1 ? fragments[1] : ""
        let magnitude = (String(fragments[0]) + String(fraction)).drop(while: { $0 == "0" })
        if magnitude.isEmpty { return 0 }
        let significant = magnitude.reversed().drop(while: { $0 == "0" }).reversed()
        let exponent = magnitude.count - significant.count - fraction.count
        guard significant.count <= 38, (-128...127).contains(exponent),
              var mantissa = Decimal(string: (canonical.hasPrefix("-") ? "-" : "") + String(significant), locale: posix)
        else { throw ConversionIssue.overflow }
        var value = Decimal()
        guard NSDecimalMultiplyByPowerOf10(&value, &mantissa, Int16(exponent), .plain) == .noError,
              !value.isNaN, value != 0
        else { throw ConversionIssue.overflow }
        return value
    }

    static func convert(_ value: Decimal, from source: MeasureUnit, to target: MeasureUnit) throws -> Decimal {
        guard source.dimension == target.dimension else { throw ConversionIssue.invalid }
        guard !value.isNaN else { throw ConversionIssue.overflow }
        guard value >= source.minimum else {
            throw source.dimension == .temperature ? ConversionIssue.absoluteZero : ConversionIssue.negative
        }
        guard value != 0 || source.dimension == .temperature else { return 0 }
        if source == target { return value }
        if source.dimension == .temperature {
            let result: Decimal
            switch (source, target) {
            case (.celsius, .fahrenheit): result = value * 9 / 5 + 32
            case (.fahrenheit, .celsius): result = (value - 32) * 5 / 9
            case (.celsius, .kelvin): result = value - source.minimum
            case (.kelvin, .celsius): result = value + target.minimum
            case (.fahrenheit, .kelvin): result = (value - source.minimum) * 5 / 9
            case (.kelvin, .fahrenheit): result = value * 9 / 5 + target.minimum
            default: throw ConversionIssue.invalid
            }
            guard !result.isNaN else { throw ConversionIssue.overflow }
            return result
        }

        let from = source.ratio, to = target.ratio
        let numerator = from.numerator * to.denominator
        let denominator = to.numerator * from.denominator
        var result = (value * numerator) / denominator
        if result.isNaN || result == 0 {
            result = value * (numerator / denominator)
        }
        guard !result.isNaN, result != 0 else { throw ConversionIssue.overflow }
        return result
    }

    static func format(_ value: Decimal, locale: Locale, input: Bool = false) -> String {
        let scientific = value != 0 && (abs(value) < decimal("0.0001") || abs(value) >= 1_000_000_000)
        if scientific {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .scientific
            formatter.exponentSymbol = "e"
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 6
            formatter.roundingMode = .halfUp
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? value.description
        }
        var original = value, rounded = value
        if !input { NSDecimalRound(&rounded, &original, 4, .plain) }
        return NSDecimalString(&rounded, locale)
    }

    static func results(_ text: String, selection: Selection, locale: Locale) throws -> ResultSet {
        let value = try parse(text, separator: locale.decimalSeparator ?? ".")
        let readings = try selection.targets.map { target in
            let converted = try convert(value, from: selection.source, to: target)
            return Reading(unit: target, number: format(converted, locale: locale))
        }
        return ResultSet(source: Reading(unit: selection.source, number: format(value, locale: locale, input: true)),
                         targets: readings)
    }
}
