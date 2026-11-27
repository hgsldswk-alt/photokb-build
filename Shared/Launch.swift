import Foundation

enum Launch {
    static let freePeriod = true

    static func value(_ flag: String, in args: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
