import Foundation

/// One sentence for a failure a person reads in the Launcher, instead of Foundation's own text.
///
/// `NSCocoaErrorDomain Code=516 "Hub Studio KH couldn't be moved to rollback-hub because an item
/// with the same name already exists", NSDestinationFilePath=…` reached the owner's window on
/// 2026-11-17. It named a path, a domain and a code, and told them nothing they could act on.
/// A `KHUError` is written for a person already, so it is passed through untouched; anything else
/// is turned into the shape of sentence the recipes use, keeping the reason but dropping the noise.
public enum PlainFailure {
    public static func sentence(_ error: Error, app: String) -> String {
        if let ours = error as? KHUError {
            return ours.message.hasPrefix(app + " ") || ours.message.contains(app)
                ? ours.message : "\(app) could not be installed: \(ours.message)"
        }
        return "\(app) could not be installed: \(reason(error))"
    }

    /// The human half of a Cocoa/NSError: its own sentence, without domain, code or file paths.
    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        var said = (ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
            ?? (ns.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? ns.localizedDescription
        // Foundation puts the path in the sentence for file errors; a person needs the cause.
        for marker in [" (Cocoa error", " (NS", " (Error Domain"] {
            if let range = said.range(of: marker) { said = String(said[said.startIndex..<range.lowerBound]) }
        }
        said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, said.rangeOfCharacter(from: .letters) != nil else {
            return "the install did not finish, and the system gave no reason"
        }
        return said
    }
}
