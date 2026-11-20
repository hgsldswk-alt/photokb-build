import Foundation

private final class LocalizationBundle: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationBundle.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    static func integer(_ value: Int) -> String { value.formatted(.number) }

    static func kb(_ bytes: Int) -> String {
        (Double(bytes) / 1_000).formatted(.number.precision(.fractionLength((bytes < 1_000_000 ? 3 : 0)...3)))
    }
}
