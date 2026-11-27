import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments

    static var isTesting: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    static var isFree: Bool { freePeriod && !(isTesting && arguments.contains("-paid-mode")) }

    static func testFlag(_ flag: String) -> Bool { isTesting && arguments.contains(flag) }

    static func value(_ flag: String) -> String? {
        guard isTesting, let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
