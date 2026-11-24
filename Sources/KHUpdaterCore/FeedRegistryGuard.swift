import Foundation

/// The registry a publish reads must be the one the commit holds.
///
/// 0.1.82's feed pass served the Launcher's `hold_url`/`hold_since` a release early: the generator
/// read a working-tree `feed-registry.json` that a session had staged for 0.1.83, and the served row
/// gained a hold the shipped build did not answer (S001, 2026-11-25). A publish is a public
/// statement about a commit, so it may only read what that commit contains.
///
/// Its refusal is its own sentence, never the publish lock's: one says another pass is running and
/// names its pid, the other says this tree is ahead of its commit and names the keys. An operator
/// told only "publish refused" has to guess which rule they broke.
public enum FeedRegistryGuard {
    /// Throws unless the file at `url` is byte-identical to its committed `HEAD` content.
    /// `shell` is a seam for tests; the real one runs `/usr/bin/git`.
    public static func requireCommitted(at url: URL, shell: Shell = SystemShell()) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard let root = topLevel(of: path, shell: shell) else {
            throw khuFail("refused: \(url.lastPathComponent) is not inside a git repository (\(path)), so there is no commit to publish from; nothing was generated")
        }
        let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        let shown: ShellResult
        do {
            shown = try shell.run("/usr/bin/git", arguments: ["-C", root, "show", "HEAD:\(relative)"], timeout: 30)
        } catch {
            throw khuFail("refused: cannot read HEAD:\(relative) (\(error)); nothing was generated")
        }
        guard shown.exitCode == 0 else {
            throw khuFail("refused: \(relative) is not committed (HEAD has no copy of it); nothing was generated. Commit the registry before publishing")
        }
        let committed = shown.stdout
        guard let working = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            throw khuFail("refused: cannot read \(relative); nothing was generated")
        }
        if working != committed {
            let keys = differingKeys(committed: Data(committed.utf8), working: Data(working.utf8))
            let named: String
            if !keys.isEmpty {
                named = keys.prefix(20).joined(separator: ", ") + (keys.count > 20 ? ", … (\(keys.count) keys)" : "")
            } else if (try? JSONSerialization.jsonObject(with: Data(working.utf8))) == nil {
                named = "working copy is not valid JSON"
            } else {
                named = "its bytes differ from HEAD but no key does (formatting only)"
            }
            throw khuFail("refused: \(relative) has uncommitted changes (\(named)); nothing was generated. "
                          + "Commit the registry before publishing — the feed states what a commit says, not what a working tree is about to say")
        }
    }

    private static func topLevel(of path: String, shell: Shell) -> String? {
        let result = try? shell.run("/usr/bin/git", arguments: ["-C", (path as NSString).deletingLastPathComponent,
                                                                "rev-parse", "--show-toplevel"], timeout: 30)
        guard let result, result.exitCode == 0 else { return nil }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The registry keys whose value differs, as `app` or `app.field`, sorted. A key equal in both
    /// is not named: the sentence is about what changed, not about how much the file holds.
    static func differingKeys(committed: Data, working: Data) -> [String] {
        guard let old = (try? JSONSerialization.jsonObject(with: committed)) as? [String: Any],
              let new = (try? JSONSerialization.jsonObject(with: working)) as? [String: Any] else {
            return []
        }
        var keys: [String] = []
        let oldApps = old["apps"] as? [String: Any] ?? [:]
        let newApps = new["apps"] as? [String: Any] ?? [:]
        for top in Set(old.keys).union(new.keys) where top != "apps" {
            if !same(old[top], new[top]) { keys.append(top) }
        }
        for app in Set(oldApps.keys).union(newApps.keys) {
            guard let before = oldApps[app] as? [String: Any],
                  let after = newApps[app] as? [String: Any] else {
                keys.append(app)                     // the whole entry appeared or went
                continue
            }
            for field in Set(before.keys).union(after.keys) where !same(before[field], after[field]) {
                keys.append("\(app).\(field)")
            }
        }
        return keys.sorted()
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a as String, b as String): return a == b
        case let (a as NSNumber, b as NSNumber): return a == b
        default:
            guard let a = lhs, let b = rhs,
                  JSONSerialization.isValidJSONObject(a), JSONSerialization.isValidJSONObject(b),
                  let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
                  let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
            return da == db
        }
    }
}
