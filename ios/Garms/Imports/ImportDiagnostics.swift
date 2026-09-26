import Foundation

nonisolated enum ImportDiagnostics {
    static func describe(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        var details = "\(ns.localizedDescription) [\(ns.domain), code \(ns.code)]"
        if let reason = ns.localizedFailureReason { details += " Reason: \(reason)" }
        if let recovery = ns.localizedRecoverySuggestion { details += " Recovery: \(recovery)" }
        if depth < 4, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            details += "\nCaused by: " + describe(underlying, depth: depth + 1)
        }
        return details
    }
}
