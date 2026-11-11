import Foundation

/// A small app bundle around one executable, so Activity Monitor and the menu bar show the
/// product name instead of a bare `khu`. The executable is a hard link to the real file (or a
/// copy when linking is refused): the version tree stays the one the stub owns, and nothing here
/// changes what runs.
public enum HelperBundle {
    /// The executable's own file name is the product name: every process list shows it, even when
    /// the process never registers with LaunchServices.
    public static let helperExecutable = "Update Studio KH Helper"
    public static let publisherExecutable = "Update Studio KH Publisher"

    public struct Spec: Sendable {
        public var name: String
        public var bundleID: String
        public var executableName: String
        public var version: String?
        public var icon: URL?

        public init(name: String, bundleID: String, executableName: String, version: String? = nil, icon: URL? = nil) {
            self.name = name
            self.bundleID = bundleID
            self.executableName = executableName
            self.version = version
            self.icon = icon
        }
    }

    /// Create or confirm `<out>/Contents/MacOS/<executableName>` for `source`, and return it.
    @discardableResult
    public static func ensure(_ spec: Spec, source: URL, out: URL, fileManager: FileManager = .default) throws -> URL {
        if let version = spec.version {
            // Loose on purpose: the version is display text here, not a path or a comparison.
            guard !version.isEmpty, !version.contains("/"), !version.contains("..") else {
                throw khuFail("not a version: \(version)")
            }
        }
        guard !spec.executableName.isEmpty, !spec.executableName.contains("/") else {
            throw khuFail("not an executable name: \(spec.executableName)")
        }
        let contents = out.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
        let executable = macos.appendingPathComponent(spec.executableName)
        if !fileManager.fileExists(atPath: executable.path) {
            do { try fileManager.linkItem(at: source, to: executable) }
            catch { try fileManager.copyItem(at: source, to: executable) }
        }
        if let icon = spec.icon, fileManager.fileExists(atPath: icon.path) {
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            let dest = resources.appendingPathComponent("AppIcon.icns")
            if !fileManager.fileExists(atPath: dest.path) { try fileManager.copyItem(at: icon, to: dest) }
        }
        let versionKeys = spec.version.map { """
        <key>CFBundleShortVersionString</key><string>\(xml($0))</string>
        <key>CFBundleVersion</key><string>\(xml($0))</string>
        """ } ?? ""
        // The feed is HTTP on the tailnet; inside a bundle macOS applies ATS, unlike the bare
        // binary this replaces. The Launcher's own Info.plist carries the same exception.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>CFBundleExecutable</key><string>\(xml(spec.executableName))</string>
        <key>CFBundleIdentifier</key><string>\(xml(spec.bundleID))</string>
        <key>CFBundleName</key><string>\(xml(spec.name))</string>
        <key>CFBundleDisplayName</key><string>\(xml(spec.name))</string>
        <key>CFBundleIconFile</key><string>AppIcon</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        \(versionKeys)
        <key>LSMinimumSystemVersion</key><string>13.0</string>
        <key>LSUIElement</key><true/>
        <key>NSAppTransportSecurity</key><dict><key>NSExceptionDomains</key><dict><key>100.64.0.0/10</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict></dict>
        </dict>
        </plist>
        """
        let plistURL = contents.appendingPathComponent("Info.plist")
        if (try? String(contentsOf: plistURL, encoding: .utf8)) != plist {
            try AtomicFile.write(Data(plist.utf8), to: plistURL)
        }
        return executable
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
