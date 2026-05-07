// swift/swiftcap/Sources/Swiftcap/RetranscribeCommand.swift
import Foundation

@available(macOS 26.0, *)
struct RetranscribeCommand {
    let sessionId: Int
    let locale: Locale
    let pass: Int

    static func parse(args: [String]) -> RetranscribeCommand? {
        var sid: Int? = nil
        var locale = Locale(identifier: "ja-JP")
        var pass = 2
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--session-id":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                sid = n; i += 2
            case "--locale":
                guard i + 1 < args.count else { return nil }
                locale = Locale(identifier: args[i + 1]); i += 2
            case "--pass":
                guard i + 1 < args.count, let n = Int(args[i + 1]) else { return nil }
                pass = n; i += 2
            default:
                i += 1
            }
        }
        guard let sid else { return nil }
        return RetranscribeCommand(sessionId: sid, locale: locale, pass: pass)
    }
}
