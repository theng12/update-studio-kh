import Foundation

/// Every place an app could come from, compared once with what this Mac has.
///
/// One place answers "what is the newest copy, and what is each other copy relative to it". Both
/// defects the owner met on 2026-11-24 came from that question being answered twice, differently: a
/// drive's older copy was offered as the update, and a newer one was never mentioned at all.
public struct AppSources: Equatable, Sendable {
    public struct Source: Equatable, Sendable {
        /// In the owner's words: "the saved feed", or the drive's own name.
        public var name: String
        public var version: String?
        public var isFeed: Bool
        public init(name: String, version: String?, isFeed: Bool = false) {
            self.name = name; self.version = version; self.isFeed = isFeed
        }
    }
    public enum Order: String, Equatable, Sendable { case newer, older, same, unknown }

    public var installed: String?
    public var sources: [Source]

    public init(installed: String?, sources: [Source] = []) {
        self.installed = installed; self.sources = sources
    }

    /// What a comparison is made against: what this Mac has, or — with no copy here yet — the feed's
    /// own version, because that is what the person would install from.
    public var baseline: String? {
        installed ?? sources.first { $0.isFeed }?.version
    }

    /// Where one source stands against the baseline. A version either side cannot read is unknown,
    /// never "current".
    public func order(_ source: Source) -> Order {
        guard let base = baseline, let v = source.version,
              VersionCompare.isValid(v), VersionCompare.isValid(base) else { return .unknown }
        if VersionCompare.isNewer(v, than: base) { return .newer }
        if VersionCompare.isNewer(base, than: v) { return .older }
        return .same
    }

    /// The copy to offer: the newest source strictly newer than the baseline, else the feed's own
    /// version when this Mac has nothing installed. Nil when nothing is newer and nothing is here.
    public var offer: String? {
        if let best = sources.filter({ order($0) == .newer })
            .max(by: { VersionCompare.isNewer($1.version ?? "", than: $0.version ?? "") }) {
            return best.version
        }
        if let installed { return installed }
        if let feed = sources.first(where: \.isFeed)?.version { return feed }
        // Nothing to compare against: the drive's own copy is what there is to install.
        return sources.compactMap(\.version).max { VersionCompare.isNewer($1, than: $0) }
    }

    public var unknown: [Source] { sources.filter { order($0) == .unknown } }

    /// One sentence naming what this Mac has and what each other copy carries, e.g.
    /// "This Mac has 0.6.255; ATLAS carries 0.6.256, newer." Nil when the feed is the only source
    /// and it says nothing the card's own version line does not already say.
    public var text: String? {
        let feedOnly = sources.count == 1 && sources[0].isFeed
        if feedOnly && installed != nil && order(sources[0]) != .unknown { return nil }
        var parts = [installed.map { "This Mac has \($0)" } ?? "This Mac has no copy yet"]
        for s in sources where !(installed == nil && s.isFeed) {
            guard let v = s.version else { parts.append("\(s.name) names no version"); continue }
            switch order(s) {
            case .newer: parts.append("\(s.name) carries \(v), newer")
            case .older: parts.append("\(s.name) carries \(v), older")
            case .same: parts.append("\(s.name) carries the same version")
            case .unknown: parts.append("\(s.name) carries a copy that cannot be compared")
            }
        }
        if sources.isEmpty, installed != nil { parts.append("no other copy is known") }
        return parts.joined(separator: "; ") + "."
    }
}
