import AppKit
import WebKit

/// Measures this app's own page, in the build that ships, for the release's tab acceptance
/// (RELEASE-POLICY §5d): the 6px gap, every tab's 32px target, the gaps between them, and the
/// selected tab's real ink and fill contrast. `KHU_SNAPSHOT_DIR` turns it on; nothing in a normal
/// run reads it. No window is ordered in or made key, nothing is typed or clicked, and the app is
/// `.accessory` throughout, so nothing appears on anyone's screen.
///
/// The images for `docs/screenshots/` are taken from `khu page` instead — the same HTML, written by
/// the served artifact — because WebKit answers a bitmap request from a bare binary with nothing
/// (measured 2026-11-24: createPDF and takeSnapshot both returned no data and no error), while its
/// layout and computed styles are exact, which is what the acceptance needs.
enum Snapshot {
    /// nil when no measurement was asked for; otherwise the process's exit code.
    static func runIfAsked() -> Int32? {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["KHU_SNAPSHOT_DIR"], !dirPath.isEmpty else { return nil }
        guard let statePath = env["KHU_SNAPSHOT_STATE"],
              let state = (try? String(contentsOf: URL(fileURLWithPath: statePath), encoding: .utf8))?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty else {
            fail("KHU_SNAPSHOT_STATE must name a readable demo-state JSON file")
            return 64
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fail("the output folder could not be created: \(error)"); return 1 }
        let widths = (env["KHU_SNAPSHOT_WIDTHS"] ?? "1440").split(separator: ",").compactMap { Int($0) }.filter { $0 >= 320 }
        let shots = (env["KHU_SNAPSHOT_SCREENS"] ?? "apps").split(separator: ",").map(String.init)
        let schemes = (env["KHU_SNAPSHOT_SCHEMES"] ?? "light").split(separator: ",").map(String.init)
        guard !widths.isEmpty, !shots.isEmpty, !schemes.isEmpty else { fail("no widths, screens or schemes to measure"); return 64 }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock tile, no activation, no front window
        var failed = 0
        for shot in shots {
            for scheme in schemes {
                for width in widths where !measure(shot: shot, scheme: scheme, width: width, state: state, dir: dir) {
                    failed += 1
                }
            }
        }
        print(failed == 0 ? "snapshot: wrote \(shots.count * schemes.count * widths.count) measurement(s) to \(dir.path)"
                          : "snapshot: \(failed) measurement(s) failed in \(dir.path)")
        return failed == 0 ? 0 : 1
    }

    private static func fail(_ text: String) {
        FileHandle.standardError.write(Data("snapshot: \(text)\n".utf8))
    }

    /// One page, one size, one scheme: render, let it settle, measure. The window is attached so
    /// WebKit lays the page out, fully transparent so it takes no pixels, and ordered out at once.
    private static func measure(shot: String, scheme: String, width: Int, state: String, dir: URL) -> Bool {
        let frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        web.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        web.wantsLayer = true
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.appearance = web.appearance
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        web.loadHTMLString(LauncherPage.html, baseURL: nil)

        var loaded = false
        let started = Date()
        while !loaded, Date().timeIntervalSince(started) < 20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if web.isLoading == false, web.url != nil { loaded = true }
        }
        guard loaded else { fail("\(shot)/\(scheme)/\(width): the page did not finish loading"); return false }

        let render = "render(\(state))" + (shot == "settings" ? ";settingsOpen=true;drawSettings()" : "")
        if let refusal = evaluate(web, render).refusal {
            fail("\(shot)/\(scheme)/\(width): the page refused its state — \(refusal)")
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))   // the sheet's 0.22s entry

        let measured = evaluate(web, measureScript(width: width))
        if let refusal = measured.refusal {
            fail("\(shot)/\(scheme)/\(width): the tab bar could not be measured — \(refusal)")
            return false
        }
        let name = "measure-\(shot)-\(scheme)-\(width).json"
        do { try Data(measured.value.utf8).write(to: dir.appendingPathComponent(name)) }
        catch { fail("\(name) could not be written: \(error)"); return false }
        return true
    }

    /// The page's answer and, when it threw, its own reason. "It refused its state" with no reason
    /// is the same defect class as "Internal error": the page knows which state it declined and why.
    /// Success is an answer of no value or empty text — `render(...)` returns nothing when it works.
    private static func evaluate(_ web: WKWebView, _ script: String) -> (value: String, refusal: String?) {
        var value = ""
        var refusal: String?
        var done = false
        web.evaluateJavaScript(script) { result, error in
            if let error { refusal = "\(error)" }
            if let text = result as? String { value = text }
            else if let result { value = "\(result)" }
            done = true
        }
        let started = Date()
        while !done, Date().timeIntervalSince(started) < 10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if !done { refusal = "no answer within 10 s" }
        return (value, refusal)
    }

    /// Measured in the rendered page: the bar's own gap, every tab's height, the gaps between them,
    /// and the selected tab's real background, ink and contrast ratio.
    private static func measureScript(width: Int) -> String {
        """
        (() => {
          const bar = document.getElementById('tabs');
          if (!bar) return JSON.stringify({width: \(width), error: 'no tab bar'});
          const tabs = [...bar.querySelectorAll('[role=tab]')];
          const sel = bar.querySelector('[aria-selected=true]');
          const cs = getComputedStyle(bar);
          const ts = getComputedStyle(sel);
          const rgb = s => (s.match(/[\\d.]+/g) || []).map(Number).slice(0, 3);
          const lin = c => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4) };
          const L = v => { const [r, g, b] = rgb(v); return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) };
          const ink = L(ts.color), fill = L(ts.backgroundColor);
          const ratio = (Math.max(ink, fill) + 0.05) / (Math.min(ink, fill) + 0.05);
          const rects = tabs.map(t => { const r = t.getBoundingClientRect();
            return {label: t.textContent, w: +r.width.toFixed(1), h: +r.height.toFixed(1), x: +r.left.toFixed(1), y: +r.top.toFixed(1)} });
          const gaps = [];
          for (let i = 1; i < rects.length; i++) if (Math.abs(rects[i].y - rects[i-1].y) < 1)
            gaps.push(+(rects[i].x - (rects[i-1].x + rects[i-1].w)).toFixed(1));
          return JSON.stringify({width: innerWidth, gapCSS: cs.gap, gaps: gaps,
            minGap: gaps.length ? Math.min(...gaps) : null, minHeight: Math.min(...rects.map(r => r.h)),
            labelWrapped: rects.some(r => r.h > 40),
            selected: {label: sel.textContent, background: ts.backgroundColor, color: ts.color,
                       contrast: +ratio.toFixed(2), fillLuminance: +fill.toFixed(3), inkLuminance: +ink.toFixed(3),
                       borderBottom: ts.borderBottomWidth + ' ' + ts.borderBottomStyle},
            tabCount: rects.length});
        })()
        """
    }
}