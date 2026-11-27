import Foundation

enum L {
    private final class Token {}
    static func t(_ key: String) -> String { NSLocalizedString(key, bundle: Bundle(for: Token.self), comment: "") }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }
}
