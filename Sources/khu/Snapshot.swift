import AppKit
import WebKit
import PDFKit

/// Offscreen captures of this app's own page for `docs/screenshots/`, produced from the build that
/// ships and only when `KHU_SNAPSHOT_DIR` names an output folder (RELEASE-POLICY §5d). No window is
/// ordered in, made key or activated, and nothing is typed or clicked: the page is rendered in a
/// window that is never shown, with the demo state the caller hands it, and rasterised from a PDF.
///
/// The same run measures the tab bar — the 6px gap, the 32px target and the selected fill's real
/// contrast — so the numbers in the receipt come from the rendered page, not from the stylesheet.
enum Snapshot {
    /// nil when snapshots were not asked for; otherwise the process's exit code.
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
        guard !widths.isEmpty, !shots.isEmpty, !schemes.isEmpty else { fail("no widths, screens or schemes to capture"); return 64 }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock tile, no activation, no front window
        var failed = 0
        for shot in shots {
            for scheme in schemes {
                for width in widths {
                    if capture(shot: shot, scheme: scheme, width: width, state: state, dir: dir) { continue }
                    failed += 1
                }
            }
        }
        print(failed == 0 ? "snapshot: wrote \(shots.count * schemes.count * widths.count) file(s) to \(dir.path)"
                          : "snapshot: \(failed) capture(s) failed in \(dir.path)")
        return failed == 0 ? 0 : 1
    }

    private static func fail(_ text: String) {
        FileHandle.standardError.write(Data("snapshot: \(text)\n".utf8))
    }

    /// One page, one size, one scheme: render, measure, rasterise, write. Never shown on screen.
    private static func capture(shot: String, scheme: String, width: Int, state: String, dir: URL) -> Bool {
        let frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        web.appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.appearance = web.appearance
        window.setIsVisible(false)          // laid out, never on screen
        web.loadHTMLString(LauncherPage.html, baseURL: nil)

        var loaded = false
        let started = Date()
        while !loaded, Date().timeIntervalSince(started) < 20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if web.isLoading == false, web.url != nil { loaded = true }
        }
        guard loaded else { fail("\(shot)/\(scheme)/\(width): the page did not finish loading"); return false }

        let render = "render(\(state))" + (shot == "settings" ? ";settingsOpen=true;drawSettings()" : "")
        guard run(web, render) != nil else { fail("\(shot)/\(scheme)/\(width): the page refused its state"); return false }
        // Let layout and the 0.22s sheet animation settle before measuring or rasterising.
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))

        if let measure = run(web, measureScript(width: width))?.data(using: .utf8) {
            try? measure.write(to: dir.appendingPathComponent("measure-\(shot)-\(scheme)-\(width).json"))
        }

        var pdf: Data?
        let pdfDone = DispatchSemaphore(value: 0)
        let config = WKPDFConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: 900)
        web.createPDF(configuration: config) { result in
            if case .success(let data) = result { pdf = data }
            pdfDone.signal()
        }
        _ = pdfDone.wait(timeout: .now() + 30)
        guard let pdf, !pdf.isEmpty else { fail("\(shot)/\(scheme)/\(width): no PDF was produced"); return false }
        guard let image = rasterise(pdf, width: width) else { fail("\(shot)/\(scheme)/\(width): the PDF could not be drawn"); return false }

        // PNG from the bitmap itself: no EXIF, no tEXt/iTXt chunks, so no author or path is written.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width),
                                        pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let name = "\(shot)-\(scheme)-\(width).png"
        do { try png.write(to: dir.appendingPathComponent(name)) }
        catch { fail("\(name) could not be written: \(error)"); return false }
        print("snapshot: \(name) \(png.count) bytes")
        return true
    }

    /// The page is rendered once at the view's own width and twice the pixel density, so text is
    /// readable in the repository and the file stays inside the 400 KB cap.
    private static func rasterise(_ pdf: Data, width: Int) -> NSImage? {
        guard let document = PDFDocument(data: pdf), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let height = bounds.height * CGFloat(width) / max(bounds.width, 1)
        let image = NSImage(size: NSSize(width: CGFloat(width) * scale, height: height * scale))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: image.size))
            context.scaleBy(x: CGFloat(width) * scale / max(bounds.width, 1), y: CGFloat(width) * scale / max(bounds.width, 1))
            page.draw(with: .mediaBox, to: context)
        }
        image.unlockFocus()
        return image
    }

    private static func run(_ web: WKWebView, _ script: String) -> String? {
        var out: String?
        var done = false
        web.evaluateJavaScript(script) { value, error in
            if let text = value as? String { out = text }
            else if let value { out = "\(value)" }
            if error != nil { out = nil }
            done = true
        }
        let started = Date()
        while !done, Date().timeIntervalSince(started) < 10 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return out
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