import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Carbon.HIToolbox
import Darwin

struct HelperFailure: Error {
    let code: String
    let message: String
}

func jsonObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "stdin must contain a JSON object")
    }
    return object
}

func payload() throws -> [String: Any] {
    try jsonObject(from: FileHandle.standardInput.readDataToEndOfFile())
}

func emit(_ object: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("failed to encode JSON: \(error)\n".utf8))
    }
}

func intValue(_ input: [String: Any], _ key: String, default fallback: Int? = nil) throws -> Int {
    if let number = input[key] as? NSNumber { return number.intValue }
    if let fallback { return fallback }
    throw HelperFailure(code: "UI_INVALID_INPUT", message: "'\(key)' must be an integer")
}

func doubleValue(_ input: [String: Any], _ key: String, default fallback: Double? = nil) throws -> Double {
    if let number = input[key] as? NSNumber { return number.doubleValue }
    if let fallback { return fallback }
    throw HelperFailure(code: "UI_INVALID_INPUT", message: "'\(key)' must be a number")
}

func stringValue(_ input: [String: Any], _ key: String, default fallback: String? = nil) throws -> String {
    if let value = input[key] as? String { return value }
    if let fallback { return fallback }
    throw HelperFailure(code: "UI_INVALID_INPUT", message: "'\(key)' must be a string")
}

func boolValue(_ input: [String: Any], _ key: String, default fallback: Bool = false) -> Bool {
    (input[key] as? NSNumber)?.boolValue ?? fallback
}

func rectDictionary(_ rect: CGRect) -> [String: Any] {
    [
        "x": Double(rect.origin.x),
        "y": Double(rect.origin.y),
        "width": Double(rect.size.width),
        "height": Double(rect.size.height),
    ]
}

func runningAppDictionary(_ app: NSRunningApplication) -> [String: Any] {
    [
        "pid": Int(app.processIdentifier),
        "name": app.localizedName ?? "",
        "bundleId": app.bundleIdentifier ?? "",
        "bundleURL": app.bundleURL?.path ?? "",
        "executableURL": app.executableURL?.path ?? "",
        "active": app.isActive,
        "hidden": app.isHidden,
        "terminated": app.isTerminated,
        "activationPolicy": app.activationPolicy.rawValue,
    ]
}

func displayDictionaries() -> [[String: Any]] {
    canonicalDisplayDictionaries()
}

func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
        throw HelperFailure(
            code: "UI_ACCESSIBILITY_PERMISSION_REQUIRED",
            message: "Accessibility permission is required for Mac Developer Bridge desktop control"
        )
    }
}

func axCopy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
    axCopy(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    (axCopy(element, attribute) as? NSNumber)?.boolValue
}

func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
    guard let raw = axCopy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
    guard let raw = axCopy(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
    return size
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axCopy(element, kAXChildrenAttribute as CFString) as? [AXUIElement]) ?? []
}

func axActions(_ element: AXUIElement) -> [String] {
    var raw: CFArray?
    guard AXUIElementCopyActionNames(element, &raw) == .success, let actions = raw as? [String] else { return [] }
    return actions
}

func boundedString(_ value: CFTypeRef?, max: Int = 2_000) -> String? {
    guard let value else { return nil }
    if CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String {
        if text.count <= max { return text }
        return String(text.prefix(max)) + "…"
    }
    if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber { return number.stringValue }
    if CFGetTypeID(value) == CFBooleanGetTypeID(), let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
    return nil
}

func fnv1a64(_ text: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1099511628211
    }
    return String(format: "%016llx", hash)
}

func elementFingerprint(_ element: AXUIElement) -> String {
    let role = axString(element, kAXRoleAttribute as CFString) ?? ""
    let subrole = axString(element, kAXSubroleAttribute as CFString) ?? ""
    let identifier = axString(element, kAXIdentifierAttribute as CFString) ?? ""
    let title = axString(element, kAXTitleAttribute as CFString) ?? ""
    let description = axString(element, kAXDescriptionAttribute as CFString) ?? ""
    let position = axPoint(element, kAXPositionAttribute as CFString)
    let size = axSize(element, kAXSizeAttribute as CFString)
    let frame = [
        position.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "",
        size.map { String(format: "%.1f,%.1f", $0.width, $0.height) } ?? "",
    ].joined(separator: "/")
    return fnv1a64([role, subrole, identifier, title, description, frame].joined(separator: "\u{1f}"))
}

func findElementsByFingerprint(pid: pid_t, expectedFingerprint: String, maxDepth: Int = 20, maxElements: Int = 5_000, maxMatches: Int = 2) -> [AXUIElement] {
    let root = AXUIElementCreateApplication(pid)
    var visited = 0
    var matches: [AXUIElement] = []

    func walk(_ element: AXUIElement, depth: Int) {
        guard visited < maxElements, matches.count < maxMatches else { return }
        visited += 1
        if elementFingerprint(element) == expectedFingerprint {
            matches.append(element)
            if matches.count >= maxMatches { return }
        }
        guard depth < maxDepth else { return }
        for child in axChildren(element) {
            walk(child, depth: depth + 1)
            if visited >= maxElements || matches.count >= maxMatches { break }
        }
    }

    walk(root, depth: 0)
    return matches
}

func elementAtPath(pid: pid_t, path: [Int], expectedFingerprint: String) throws -> AXUIElement {
    var current = AXUIElementCreateApplication(pid)
    var pathValid = true
    for index in path {
        let children = axChildren(current)
        guard index >= 0 && index < children.count else {
            pathValid = false
            break
        }
        current = children[index]
    }
    if pathValid, elementFingerprint(current) == expectedFingerprint {
        return current
    }

    // Accessibility child arrays can be re-indexed by transient AppKit controls even
    // when the observed target itself is unchanged. Recover only the exact observed
    // identity, and only when it is unique. A changed frame/title/role/etc. changes
    // the fingerprint and still fails closed as UI_ELEMENT_STALE.
    let matches = findElementsByFingerprint(pid: pid, expectedFingerprint: expectedFingerprint)
    guard matches.count == 1, let recovered = matches.first else {
        let reason = matches.isEmpty
            ? "Accessibility element changed or disappeared since observation"
            : "Accessibility element fingerprint is no longer unique"
        throw HelperFailure(code: "UI_ELEMENT_STALE", message: "\(reason); re-run ui_tree/ui_observe before acting")
    }
    return recovered
}

func parseRef(_ ref: String) throws -> (pid_t, [Int], String) {
    let parts = ref.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "ax", let pid = pid_t(parts[1]) else {
        throw HelperFailure(code: "UI_INVALID_ELEMENT_REF", message: "element ref must have the form ax:<pid>:<path>:<fingerprint>")
    }
    let pathText = String(parts[2])
    let fingerprint = String(parts[3])
    guard fingerprint.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil else {
        throw HelperFailure(code: "UI_INVALID_ELEMENT_REF", message: "element ref has an invalid fingerprint")
    }
    if pathText == "root" || pathText.isEmpty { return (pid, [], fingerprint) }
    let path = try pathText.split(separator: ".").map { part -> Int in
        guard let value = Int(part), value >= 0 else {
            throw HelperFailure(code: "UI_INVALID_ELEMENT_REF", message: "element ref contains an invalid child index")
        }
        return value
    }
    return (pid, path, fingerprint)
}

func elementRef(_ element: AXUIElement, pid: pid_t, path: [Int]) -> String {
    let pathText = path.isEmpty ? "root" : path.map(String.init).joined(separator: ".")
    return "ax:\(pid):\(pathText):\(elementFingerprint(element))"
}

func describeAXElement(_ element: AXUIElement, pid: pid_t, path: [Int], includeValue: Bool) -> [String: Any] {
    let role = axString(element, kAXRoleAttribute as CFString) ?? ""
    let subrole = axString(element, kAXSubroleAttribute as CFString) ?? ""
    let secure = role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure")
    let position = axPoint(element, kAXPositionAttribute as CFString)
    let size = axSize(element, kAXSizeAttribute as CFString)
    var result: [String: Any] = [
        "ref": elementRef(element, pid: pid, path: path),
        "role": role,
        "subrole": subrole,
        "title": axString(element, kAXTitleAttribute as CFString) ?? "",
        "description": axString(element, kAXDescriptionAttribute as CFString) ?? "",
        "identifier": axString(element, kAXIdentifierAttribute as CFString) ?? "",
        "actions": axActions(element),
    ]
    if let enabled = axBool(element, kAXEnabledAttribute as CFString) { result["enabled"] = enabled }
    if let focused = axBool(element, kAXFocusedAttribute as CFString) { result["focused"] = focused }
    if let position, let size {
        result["frame"] = rectDictionary(CGRect(origin: position, size: size))
    }
    if includeValue {
        if secure {
            result["value"] = "<redacted>"
            result["secure"] = true
        } else if let value = boundedString(axCopy(element, kAXValueAttribute as CFString)) {
            result["value"] = value
        }
    }
    return result
}

func axTree(pid: pid_t, maxDepth: Int, maxElements: Int, includeValues: Bool) throws -> [String: Any] {
    try requireAccessibility()
    let root = AXUIElementCreateApplication(pid)
    var emitted = 0
    var truncated = false

    func walk(_ element: AXUIElement, path: [Int], depth: Int) -> [String: Any] {
        var item = describeAXElement(element, pid: pid, path: path, includeValue: includeValues)
        emitted += 1
        guard depth < maxDepth, emitted < maxElements else {
            if !axChildren(element).isEmpty { truncated = true }
            return item
        }
        let children = axChildren(element)
        var childItems: [[String: Any]] = []
        for (index, child) in children.enumerated() {
            if emitted >= maxElements { truncated = true; break }
            childItems.append(walk(child, path: path + [index], depth: depth + 1))
        }
        if !childItems.isEmpty { item["children"] = childItems }
        return item
    }

    let rootDescription = walk(root, path: [], depth: 0)
    return [
        "pid": Int(pid),
        "maxDepth": maxDepth,
        "maxElements": maxElements,
        "elementCount": emitted,
        "truncated": truncated,
        "root": rootDescription,
    ]
}

func targetPid(_ input: [String: Any]) throws -> pid_t {
    if let number = input["pid"] as? NSNumber { return pid_t(number.int32Value) }
    guard let app = NSWorkspace.shared.frontmostApplication else {
        throw HelperFailure(code: "UI_NO_FRONTMOST_APP", message: "No frontmost application is available")
    }
    return app.processIdentifier
}

func windowList(maxWindows: Int, onScreenOnly: Bool) -> [[String: Any]] {
    var options: CGWindowListOption = [.excludeDesktopElements]
    if onScreenOnly { options.insert(.optionOnScreenOnly) }
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return raw.prefix(maxWindows).map { window in
        let boundsRaw = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        var rect = CGRect.zero
        CGRectMakeWithDictionaryRepresentation(boundsRaw as CFDictionary, &rect)
        var item: [String: Any] = [
            "windowId": (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0,
            "ownerPid": (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0,
            "ownerName": window[kCGWindowOwnerName as String] as? String ?? "",
            "name": window[kCGWindowName as String] as? String ?? "",
            "layer": (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            "alpha": (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
            "onScreen": (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            "memoryBytes": (window[kCGWindowMemoryUsage as String] as? NSNumber)?.intValue ?? 0,
            "bounds": rectDictionary(rect),
        ]
        item.merge(displayRouting(for: rect)) { current, _ in current }
        return item
    }
}

@available(macOS 14.0, *)
func captureDisplay(displayId: CGDirectDisplayID, maxWidth: Int, maxHeight: Int, includeCursor: Bool) async throws -> CGImage {
    guard CGPreflightScreenCaptureAccess() else {
        throw HelperFailure(code: "UI_SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Screen Recording permission is required for screenshots")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayId }) else {
        throw HelperFailure(code: "UI_DISPLAY_NOT_FOUND", message: "Display \(displayId) is not available")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    let sourceWidth = max(1, Int(display.width))
    let sourceHeight = max(1, Int(display.height))
    let widthScale = Double(maxWidth) / Double(sourceWidth)
    let heightScale = Double(maxHeight) / Double(sourceHeight)
    let scale = min(1.0, widthScale, heightScale)
    config.width = max(1, Int(Double(sourceWidth) * scale))
    config.height = max(1, Int(Double(sourceHeight) * scale))
    config.showsCursor = includeCursor
    config.capturesAudio = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

func encodeImage(_ image: CGImage, format: String, quality: Double) throws -> (String, Data) {
    let rep = NSBitmapImageRep(cgImage: image)
    switch format.lowercased() {
    case "png":
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw HelperFailure(code: "UI_SCREENSHOT_ENCODE_FAILED", message: "Could not encode PNG screenshot")
        }
        return ("image/png", data)
    case "jpeg", "jpg":
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: max(0.1, min(1.0, quality))]) else {
            throw HelperFailure(code: "UI_SCREENSHOT_ENCODE_FAILED", message: "Could not encode JPEG screenshot")
        }
        return ("image/jpeg", data)
    default:
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "format must be 'jpeg' or 'png'")
    }
}

func findRunningApplication(_ input: [String: Any]) throws -> NSRunningApplication {
    let apps = NSWorkspace.shared.runningApplications
    if let pid = (input["pid"] as? NSNumber)?.int32Value,
       let app = apps.first(where: { $0.processIdentifier == pid }) { return app }
    if let bundleId = input["bundle_id"] as? String,
       let app = apps.first(where: { $0.bundleIdentifier == bundleId }) { return app }
    if let name = input["name"] as? String,
       let app = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) { return app }
    throw HelperFailure(code: "UI_APP_NOT_RUNNING", message: "No matching running application was found")
}

func applicationURL(named name: String) -> URL? {
    if let running = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
    }), let bundleURL = running.bundleURL {
        return bundleURL
    }
    let bundleName = name.lowercased().hasSuffix(".app") ? name : "\(name).app"
    let roots = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
    ]
    for root in roots {
        let candidate = URL(fileURLWithPath: root).appendingPathComponent(bundleName)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

func launchApplication(_ input: [String: Any]) async throws -> NSRunningApplication {
    let workspace = NSWorkspace.shared
    let url: URL
    if let path = input["path"] as? String {
        url = URL(fileURLWithPath: path)
    } else if let bundleId = input["bundle_id"] as? String, let found = workspace.urlForApplication(withBundleIdentifier: bundleId) {
        url = found
    } else if let name = input["name"] as? String, let found = applicationURL(named: name) {
        url = found
    } else {
        throw HelperFailure(code: "UI_APP_NOT_FOUND", message: "Supply a valid path, bundle_id, or application name")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = boolValue(input, "activate", default: true)
    return try await workspace.openApplication(at: url, configuration: configuration)
}

func activateApplication(_ app: NSRunningApplication) throws {
    guard app.activate(options: [.activateIgnoringOtherApps]) else {
        throw HelperFailure(code: "UI_APP_ACTIVATE_FAILED", message: "macOS refused to activate \(app.localizedName ?? String(app.processIdentifier))")
    }
}

func performAXAction(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let ref = try stringValue(input, "ref")
    let (pid, path, fingerprint) = try parseRef(ref)
    let element = try elementAtPath(pid: pid, path: path, expectedFingerprint: fingerprint)
    if let precondition = input["precondition"] as? [String: Any], !axElementMatches(element, selector: precondition) {
        throw HelperFailure(code: "UI_PRECONDITION_FAILED", message: "Accessibility element no longer satisfies the requested precondition")
    }
    let action = try stringValue(input, "action").lowercased()

    if action == "set_value" {
        let value = try stringValue(input, "value", default: "")
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard result == .success else {
            throw HelperFailure(code: "UI_AX_ACTION_FAILED", message: "AX set_value failed with error \(result.rawValue)")
        }
    } else if action == "focus" {
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard result == .success else {
            throw HelperFailure(code: "UI_AX_ACTION_FAILED", message: "AX focus failed with error \(result.rawValue)")
        }
    } else {
        let mapping: [String: CFString] = [
            "press": kAXPressAction as CFString,
            "raise": kAXRaiseAction as CFString,
            "confirm": kAXConfirmAction as CFString,
            "cancel": kAXCancelAction as CFString,
            "increment": kAXIncrementAction as CFString,
            "decrement": kAXDecrementAction as CFString,
            "show_menu": kAXShowMenuAction as CFString,
        ]
        guard let axAction = mapping[action] else {
            throw HelperFailure(code: "UI_INVALID_INPUT", message: "Unsupported AX action '\(action)'")
        }
        let result = AXUIElementPerformAction(element, axAction)
        guard result == .success else {
            throw HelperFailure(code: "UI_AX_ACTION_FAILED", message: "AX action \(action) failed with error \(result.rawValue)")
        }
    }
    return ["ref": ref, "action": action, "performed": true]
}

func postMouse(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let action = try stringValue(input, "action").lowercased()
    let point = (action == "scroll")
        ? CGPoint(x: try doubleValue(input, "x", default: 0), y: try doubleValue(input, "y", default: 0))
        : try globalPoint(input)
    switch action {
    case "move":
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    case "click", "double_click", "right_click":
        let right = action == "right_click"
        let button: CGMouseButton = right ? .right : .left
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let count: Int64 = action == "double_click" ? 2 : 1
        for click in 1...count {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create mouse event")
            }
            down.setIntegerValueField(.mouseEventClickState, value: click)
            up.setIntegerValueField(.mouseEventClickState, value: click)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    case "drag":
        let destination = CGPoint(
            x: try doubleValue(input, "to_x"),
            y: try doubleValue(input, "to_y")
        )
        let to: CGPoint
        if let display = input["to_display_id"] as? NSNumber {
            let bounds = try canonicalDisplayBounds(CGDirectDisplayID(display.uint32Value))
            to = CGPoint(x: destination.x + bounds.minX, y: destination.y + bounds.minY)
        } else {
            to = destination
        }
        let duration = max(0, min(10_000, try intValue(input, "duration_ms", default: 450)))
        try performDrag(from: point, to: to, durationMs: duration)
        return ["action": action, "from": ["x": point.x, "y": point.y], "to": ["x": to.x, "y": to.y], "durationMs": duration, "performed": true]
    case "scroll":
        let dx = Int32(try doubleValue(input, "delta_x", default: 0))
        let dy = Int32(try doubleValue(input, "delta_y", default: 0))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
            throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
    default:
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "Unsupported mouse action '\(action)'")
    }
    var result: [String: Any] = ["action": action, "performed": true]
    if action != "scroll" { result["x"] = point.x; result["y"] = point.y }
    return result
}

func keyCode(_ name: String) -> CGKeyCode? {
    let key = name.lowercased()
    let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
        "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
        "forward_delete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "page_down": kVK_PageDown, "help": kVK_Help,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "left_bracket": kVK_ANSI_LeftBracket, "right_bracket": kVK_ANSI_RightBracket,
        "quote": kVK_ANSI_Quote, "semicolon": kVK_ANSI_Semicolon, "backslash": kVK_ANSI_Backslash, "comma": kVK_ANSI_Comma,
        "slash": kVK_ANSI_Slash, "period": kVK_ANSI_Period, "grave": kVK_ANSI_Grave,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
        "f19": kVK_F19, "f20": kVK_F20, "volume_up": kVK_VolumeUp, "volume_down": kVK_VolumeDown, "mute": kVK_Mute,
        "keypad_0": kVK_ANSI_Keypad0, "keypad_1": kVK_ANSI_Keypad1, "keypad_2": kVK_ANSI_Keypad2, "keypad_3": kVK_ANSI_Keypad3,
        "keypad_4": kVK_ANSI_Keypad4, "keypad_5": kVK_ANSI_Keypad5, "keypad_6": kVK_ANSI_Keypad6, "keypad_7": kVK_ANSI_Keypad7,
        "keypad_8": kVK_ANSI_Keypad8, "keypad_9": kVK_ANSI_Keypad9, "keypad_enter": kVK_ANSI_KeypadEnter,
        "keypad_plus": kVK_ANSI_KeypadPlus, "keypad_minus": kVK_ANSI_KeypadMinus, "keypad_multiply": kVK_ANSI_KeypadMultiply,
        "keypad_divide": kVK_ANSI_KeypadDivide, "keypad_decimal": kVK_ANSI_KeypadDecimal,
    ]
    return keys[key].map(CGKeyCode.init)
}

func eventFlags(_ names: [String]) -> CGEventFlags {
    var flags: CGEventFlags = []
    for name in names.map({ $0.lowercased() }) {
        switch name {
        case "command", "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        case "fn", "function": flags.insert(.maskSecondaryFn)
        default: break
        }
    }
    return flags
}

func postKeyboard(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    if let text = input["text"] as? String {
        let units = Array(text.utf16)
        // CGEvent's Unicode payload is not an appropriate place for an unbounded
        // 500k-character string. Send bounded UTF-16 chunks and never split a
        // surrogate pair across events.
        var offset = 0
        while offset < units.count {
            var end = min(units.count, offset + 1_024)
            if end < units.count {
                let previous = units[end - 1]
                if previous >= 0xD800 && previous <= 0xDBFF { end -= 1 }
            }
            if end <= offset { end = min(units.count, offset + 2) }
            let chunk = Array(units[offset..<end])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create keyboard event")
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            offset = end
        }
        return ["typedCharacters": text.count, "performed": true]
    }
    let key = input["key"] as? String
    let code: CGKeyCode
    if let raw = input["key_code"] as? NSNumber {
        guard raw.intValue >= 0 && raw.intValue <= 255 else {
            throw HelperFailure(code: "UI_INVALID_INPUT", message: "key_code must be between 0 and 255")
        }
        code = CGKeyCode(raw.uint16Value)
    } else if let key, let mapped = keyCode(key) {
        code = mapped
    } else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "Supply a supported key name or key_code")
    }
    let modifiers = input["modifiers"] as? [String] ?? []
    let flags = eventFlags(modifiers)
    let phase = (input["phase"] as? String)?.lowercased() ?? "press"
    guard ["press", "down", "up"].contains(phase) else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "phase must be press, down, or up")
    }
    let repeats = max(1, min(100, (input["repeat"] as? NSNumber)?.intValue ?? 1))
    let delayMs = max(0, min(2_000, (input["delay_ms"] as? NSNumber)?.intValue ?? 0))
    for index in 0..<repeats {
        if phase != "up" {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
                throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create key-down event")
            }
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if phase != "down" {
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create key-up event")
            }
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
        if delayMs > 0 && index + 1 < repeats { usleep(useconds_t(delayMs * 1_000)) }
    }
    return ["key": key ?? "", "keyCode": Int(code), "modifiers": modifiers, "phase": phase, "repeat": repeats, "performed": true]
}

func clipboardRead() -> [String: Any] {
    let pasteboard = NSPasteboard.general
    return [
        "changeCount": pasteboard.changeCount,
        "string": pasteboard.string(forType: .string) ?? "",
        "types": pasteboard.types?.map(\.rawValue) ?? [],
    ]
}

func clipboardWrite(_ input: [String: Any]) throws -> [String: Any] {
    let text = try stringValue(input, "text", default: "")
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
        throw HelperFailure(code: "UI_CLIPBOARD_WRITE_FAILED", message: "Could not write text to the clipboard")
    }
    return ["writtenCharacters": text.count, "changeCount": pasteboard.changeCount]
}

@main
struct MacUIHelper {
    static func main() async {
        do {
            guard CommandLine.arguments.count >= 2 else {
                throw HelperFailure(code: "UI_INVALID_COMMAND", message: "A helper command is required")
            }
            let command = CommandLine.arguments[1]
            let input = try payload()
            let result: [String: Any]

            switch command {
            case "status":
                let frontmost = NSWorkspace.shared.frontmostApplication
                result = [
                    "helperVersion": "1.0.0",
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                    "accessibilityTrusted": AXIsProcessTrusted(),
                    "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
                    "frontmostApplication": frontmost.map(runningAppDictionary) ?? NSNull(),
                    "displays": displayDictionaries(),
                ]
            case "apps":
                let apps = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy != .prohibited || boolValue(input, "include_background", default: false) }
                    .map(runningAppDictionary)
                result = ["applications": apps]
            case "windows":
                let maxWindows = max(1, min(2_000, try intValue(input, "max_windows", default: 300)))
                result = ["windows": windowList(maxWindows: maxWindows, onScreenOnly: boolValue(input, "on_screen_only", default: true))]
            case "tree":
                let pid = try targetPid(input)
                let depth = max(0, min(20, try intValue(input, "max_depth", default: 8)))
                let elements = max(1, min(5_000, try intValue(input, "max_elements", default: 500)))
                result = try axTree(pid: pid, maxDepth: depth, maxElements: elements, includeValues: boolValue(input, "include_values", default: true))
            case "screenshot":
                guard #available(macOS 14.0, *) else {
                    throw HelperFailure(code: "UI_SCREENSHOT_UNSUPPORTED", message: "Native screenshots require macOS 14 or newer")
                }
                let capture = try await captureNativeTarget(input)
                result = try encodedCaptureDictionary(
                    capture,
                    format: try stringValue(input, "format", default: "jpeg"),
                    quality: try doubleValue(input, "quality", default: 0.78)
                )
            case "ocr":
                guard #available(macOS 14.0, *) else {
                    throw HelperFailure(code: "UI_SCREENSHOT_UNSUPPORTED", message: "OCR capture requires macOS 14 or newer")
                }
                let capture = try await captureNativeTarget(input)
                var ocr = try recognizeText(capture.image, input: input)
                ocr["target"] = capture.target
                if boolValue(input, "include_screenshot", default: false) {
                    let encoded = try encodeImage(capture.image, format: try stringValue(input, "format", default: "jpeg"), quality: try doubleValue(input, "quality", default: 0.72))
                    ocr["mimeType"] = encoded.0
                    ocr["data"] = encoded.1.base64EncodedString()
                    ocr["width"] = capture.image.width
                    ocr["height"] = capture.image.height
                }
                result = ocr
            case "wait_visual":
                guard #available(macOS 14.0, *) else {
                    throw HelperFailure(code: "UI_SCREENSHOT_UNSUPPORTED", message: "Visual waits require macOS 14 or newer")
                }
                result = try await waitForVisualCondition(input)
            case "wait_for":
                result = try waitForAXCondition(input)
            case "assert":
                result = try assertAXCondition(input)
            case "window_action":
                result = try performWindowAction(input)
            case "drag_drop":
                result = try performDragDrop(input)
            case "dialogs":
                result = try dialogList(input)
            case "dialog_action":
                result = try performDialogAction(input)
            case "file_dialog":
                result = try performFileDialog(input)
            case "app_launch":
                result = runningAppDictionary(try await launchApplication(input))
            case "app_activate":
                let app = try findRunningApplication(input)
                try activateApplication(app)
                result = runningAppDictionary(app)
            case "action":
                result = try performAXAction(input)
            case "mouse":
                result = try postMouse(input)
            case "keyboard":
                result = try postKeyboard(input)
            case "clipboard_read":
                result = clipboardRead()
            case "clipboard_write":
                result = try clipboardWrite(input)
            default:
                throw HelperFailure(code: "UI_INVALID_COMMAND", message: "Unknown helper command '\(command)'")
            }
            emit(["ok": true, "result": result])
        } catch let error as HelperFailure {
            emit(["ok": false, "error": ["code": error.code, "message": error.message]])
            exit(2)
        } catch {
            emit(["ok": false, "error": ["code": "UI_HELPER_ERROR", "message": String(describing: error)]])
            exit(1)
        }
    }
}
