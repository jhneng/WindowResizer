import AppKit
import ApplicationServices

struct RunningTarget: Identifiable, Hashable {
    let id: pid_t
    let name: String
}

enum ResizeError: LocalizedError {
    case noPermission, appNotFound, noWindow, failed(String)
    var errorDescription: String? {
        switch self {
        case .noPermission:  return "Accessibility permission not granted."
        case .appNotFound:   return "App not running."
        case .noWindow:      return "No resizable window found. Make sure the app has an open window."
        case .failed(let s): return "Resize failed: \(s)"
        }
    }
}

enum WindowResizer {

    enum Snap { case left, right, center }

    // MARK: - Permission

    static func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Opens System Settings directly at Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App discovery

    /// Apps running with a normal UI, deduped and sorted by name.
    static func runningApps() -> [RunningTarget] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningTarget(id: app.processIdentifier, name: name)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Public actions

    static func resize(pid: pid_t, to size: CGSize) async throws {
        guard hasPermission() else {
            requestPermission()
            throw ResizeError.noPermission
        }
        let window = try await resolveWindow(pid: pid)
        let origin = currentPosition(of: window) ?? .zero
        try await animate(window: window, to: CGRect(origin: origin, size: size))
    }

    static func snap(pid: pid_t, to snap: Snap) async throws {
        guard hasPermission() else {
            requestPermission()
            throw ResizeError.noPermission
        }
        let window = try await resolveWindow(pid: pid)

        // Locate the screen the window currently sits on.
        let pos = currentPosition(of: window) ?? .zero
        let screen = screenContaining(axPoint: pos) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame   // Cocoa coords; excludes menu bar + Dock

        let targetCocoa: CGRect
        switch snap {
        case .left:
            targetCocoa = CGRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case .right:
            targetCocoa = CGRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case .center:
            let size = currentSize(of: window) ?? CGSize(width: vf.width / 2, height: vf.height / 2)
            targetCocoa = CGRect(x: vf.midX - size.width / 2,
                                 y: vf.midY - size.height / 2,
                                 width: size.width, height: size.height)
        }

        try await animate(window: window, to: cocoaToAX(targetCocoa))
    }

    // MARK: - Animation

    /// Smoothly interpolates the window from its current frame to `target` in AX coords.
    /// Uses an ease-out cubic curve over `duration` seconds at ~60 fps.
    private static func animate(
        window: AXUIElement,
        to target: CGRect,
        duration: Double = 0.18
    ) async throws {
        let from = CGRect(
            origin: currentPosition(of: window) ?? target.origin,
            size: currentSize(of: window) ?? target.size
        )

        let frameCount = max(1, Int((duration * 60).rounded()))
        let frameNanos = UInt64(duration / Double(frameCount) * 1_000_000_000)

        for frame in 1...frameCount {
            let t = Double(frame) / Double(frameCount)
            let eased = 1 - pow(1 - t, 3)

            let step = CGRect(
                x: from.minX + (target.minX - from.minX) * eased,
                y: from.minY + (target.minY - from.minY) * eased,
                width: from.width + (target.width - from.width) * eased,
                height: from.height + (target.height - from.height) * eased
            )

            // Size before position so the window doesn't clip off-screen mid-move.
            try setSize(of: window, to: step.size)
            try setPosition(of: window, to: step.origin)

            if frame < frameCount {
                try? await Task.sleep(nanoseconds: frameNanos)
            }
        }
    }

    // MARK: - Window resolution

    /// Brings the target app forward (so it has a focused window) and then
    /// finds a usable window, retrying briefly because activation is async.
    /// This is what makes Electron apps like Spotify work.
    private static func resolveWindow(pid: pid_t) async throws -> AXUIElement {
        let appElement = AXUIElementCreateApplication(pid)

        if let running = NSRunningApplication(processIdentifier: pid) {
            running.activate()
        } else {
            throw ResizeError.appNotFound
        }

        // Up to ~0.5s total: activation + window creation can lag a moment.
        for attempt in 0..<7 {
            if let w = window(of: appElement) { return w }
            if attempt < 6 {
                try? await Task.sleep(nanoseconds: 70_000_000) // 70 ms
            }
        }
        throw ResizeError.noWindow
    }

    /// Tries focused window, then main window, then the first window in the list.
    private static func window(of app: AXUIElement) -> AXUIElement? {
        if let w = copyWindowAttr(app, kAXFocusedWindowAttribute) { return w }
        if let w = copyWindowAttr(app, kAXMainWindowAttribute) { return w }

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
           let arr = ref as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    private static func copyWindowAttr(_ app: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attr as CFString, &ref) == .success,
              let element = ref,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    // MARK: - AX primitives

    private static func setSize(of window: AXUIElement, to size: CGSize) throws {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { throw ResizeError.failed("encode size") }
        let r = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        guard r == .success else { throw ResizeError.failed("AX size \(r.rawValue)") }
    }

    private static func setPosition(of window: AXUIElement, to point: CGPoint) throws {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { throw ResizeError.failed("encode position") }
        let r = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        guard r == .success else { throw ResizeError.failed("AX position \(r.rawValue)") }
    }

    private static func currentSize(of window: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &ref) == .success,
              let v = ref,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func currentPosition(of window: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &ref) == .success,
              let v = ref,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    // MARK: - Coordinate conversion (Cocoa bottom-left ↔ AX top-left)

    private static func primaryHeight() -> CGFloat? {
        (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?
            .frame.height
    }

    private static func cocoaToAX(_ rect: CGRect) -> CGRect {
        guard let h = primaryHeight() else { return rect }
        return CGRect(x: rect.minX, y: h - rect.minY - rect.height,
                      width: rect.width, height: rect.height)
    }

    private static func screenContaining(axPoint: CGPoint) -> NSScreen? {
        guard primaryHeight() != nil else { return nil }
        return NSScreen.screens.first { cocoaToAX($0.frame).contains(axPoint) }
    }
}
