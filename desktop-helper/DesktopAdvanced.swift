import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Vision
import Carbon.HIToolbox

// MARK: - Canonical display geometry

func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = Array(repeating: CGDirectDisplayID(0), count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func appKitScreen(displayId: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { screen in
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        return id == displayId
    }
}

func canonicalDisplayDictionaries() -> [[String: Any]] {
    activeDisplayIDs().map { displayId in
        let quartz = CGDisplayBounds(displayId)
        let screen = appKitScreen(displayId: displayId)
        let mode = CGDisplayCopyDisplayMode(displayId)
        let logicalWidth = max(1.0, quartz.width)
        let logicalHeight = max(1.0, quartz.height)
        let pixelWidth = mode.map { Double($0.pixelWidth) } ?? logicalWidth
        let pixelHeight = mode.map { Double($0.pixelHeight) } ?? logicalHeight
        return [
            "displayId": Int(displayId),
            "name": screen?.localizedName ?? "Display \(displayId)",
            // Canonical coordinate system used by ui_mouse/ui_drag_drop/region capture:
            // Quartz global display space, in points, with the primary display at 0,0.
            "bounds": rectDictionary(quartz),
            "quartzBounds": rectDictionary(quartz),
            "appKitFrame": screen.map { rectDictionary($0.frame) } ?? NSNull(),
            "visibleFrame": screen.map { rectDictionary($0.visibleFrame) } ?? NSNull(),
            "backingScaleFactor": screen?.backingScaleFactor ?? 1.0,
            "pixelWidth": Int(pixelWidth),
            "pixelHeight": Int(pixelHeight),
            "pixelScaleX": pixelWidth / logicalWidth,
            "pixelScaleY": pixelHeight / logicalHeight,
            "main": displayId == CGMainDisplayID(),
        ]
    }
}

func canonicalDisplayBounds(_ displayId: CGDirectDisplayID) throws -> CGRect {
    guard activeDisplayIDs().contains(displayId) else {
        throw HelperFailure(code: "UI_DISPLAY_NOT_FOUND", message: "Display \(displayId) is not active")
    }
    return CGDisplayBounds(displayId)
}

func displayForGlobalPoint(_ point: CGPoint) -> CGDirectDisplayID? {
    activeDisplayIDs().first { CGDisplayBounds($0).contains(point) }
}

func displayForGlobalRect(_ rect: CGRect) -> CGDirectDisplayID? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return displayForGlobalPoint(center)
}

func globalPoint(_ input: [String: Any], prefix: String = "") throws -> CGPoint {
    let xKey = prefix.isEmpty ? "x" : "\(prefix)_x"
    let yKey = prefix.isEmpty ? "y" : "\(prefix)_y"
    var point = CGPoint(
        x: try doubleValue(input, xKey),
        y: try doubleValue(input, yKey)
    )
    let displayKey = prefix.isEmpty ? "display_id" : "\(prefix)_display_id"
    if let number = input[displayKey] as? NSNumber {
        let displayId = CGDirectDisplayID(number.uint32Value)
        let bounds = try canonicalDisplayBounds(displayId)
        point.x += bounds.origin.x
        point.y += bounds.origin.y
    }
    return point
}

func rectFromDictionary(_ raw: [String: Any], displayId: CGDirectDisplayID? = nil) throws -> CGRect {
    var rect = CGRect(
        x: try doubleValue(raw, "x"),
        y: try doubleValue(raw, "y"),
        width: try doubleValue(raw, "width"),
        height: try doubleValue(raw, "height")
    )
    guard rect.width > 0, rect.height > 0 else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "region width and height must be positive")
    }
    if let displayId {
        let display = try canonicalDisplayBounds(displayId)
        rect.origin.x += display.origin.x
        rect.origin.y += display.origin.y
    }
    return rect
}

func displayRouting(for rect: CGRect) -> [String: Any] {
    guard let displayId = displayForGlobalRect(rect) else { return [:] }
    let bounds = CGDisplayBounds(displayId)
    return [
        "displayId": Int(displayId),
        "displayLocalBounds": rectDictionary(CGRect(
            x: rect.origin.x - bounds.origin.x,
            y: rect.origin.y - bounds.origin.y,
            width: rect.width,
            height: rect.height
        )),
    ]
}

// MARK: - Screenshot targets

struct NativeCapture {
    let image: CGImage
    let target: [String: Any]
}

func scaledImage(_ image: CGImage, maxWidth: Int, maxHeight: Int) throws -> CGImage {
    let sourceWidth = image.width
    let sourceHeight = image.height
    let scale = min(1.0, Double(maxWidth) / Double(sourceWidth), Double(maxHeight) / Double(sourceHeight))
    guard scale < 0.999 else { return image }
    let width = max(1, Int(Double(sourceWidth) * scale))
    let height = max(1, Int(Double(sourceHeight) * scale))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw HelperFailure(code: "UI_SCREENSHOT_SCALE_FAILED", message: "Could not allocate image scaling context")
    }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else {
        throw HelperFailure(code: "UI_SCREENSHOT_SCALE_FAILED", message: "Could not render scaled screenshot")
    }
    return result
}

@available(macOS 14.0, *)
func captureWindow(windowId: CGWindowID, maxWidth: Int, maxHeight: Int, includeCursor: Bool) async throws -> NativeCapture {
    await MainActor.run { _ = NSApplication.shared }
    guard CGPreflightScreenCaptureAccess() else {
        throw HelperFailure(code: "UI_SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Screen Recording permission is required for screenshots")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
        throw HelperFailure(code: "UI_WINDOW_NOT_FOUND", message: "Window \(windowId) is not shareable or no longer exists")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let frame = window.frame
    let desiredScale = appKitScreen(displayId: displayForGlobalRect(frame) ?? CGMainDisplayID())?.backingScaleFactor ?? 2.0
    let sourceWidth = max(1, Int(frame.width * desiredScale))
    let sourceHeight = max(1, Int(frame.height * desiredScale))
    let scale = min(1.0, Double(maxWidth) / Double(sourceWidth), Double(maxHeight) / Double(sourceHeight))
    config.width = max(1, Int(Double(sourceWidth) * scale))
    config.height = max(1, Int(Double(sourceHeight) * scale))
    config.showsCursor = includeCursor
    config.capturesAudio = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    var target: [String: Any] = [
        "kind": "window",
        "windowId": Int(window.windowID),
        "title": window.title ?? "",
        "frame": rectDictionary(frame),
        "onScreen": window.isOnScreen,
        "active": window.isActive,
        "ownerPid": window.owningApplication.map { Int($0.processID) } ?? 0,
        "ownerBundleId": window.owningApplication?.bundleIdentifier ?? "",
        "ownerName": window.owningApplication?.applicationName ?? "",
    ]
    target.merge(displayRouting(for: frame)) { current, _ in current }
    return NativeCapture(image: image, target: target)
}

@available(macOS 14.0, *)
func captureRegion(_ rect: CGRect, maxWidth: Int, maxHeight: Int, includeCursor: Bool) async throws -> NativeCapture {
    guard CGPreflightScreenCaptureAccess() else {
        throw HelperFailure(code: "UI_SCREEN_RECORDING_PERMISSION_REQUIRED", message: "Screen Recording permission is required for screenshots")
    }
    let image: CGImage
    if #available(macOS 15.2, *) {
        image = try await SCScreenshotManager.captureImage(in: rect)
    } else {
        // The pre-15.2 public API only has per-display filters. Restrict the fallback
        // to one display rather than silently returning the wrong geometry.
        guard let displayId = displayForGlobalRect(rect) else {
            throw HelperFailure(code: "UI_REGION_OUTSIDE_DISPLAYS", message: "Region does not intersect an active display")
        }
        let bounds = try canonicalDisplayBounds(displayId)
        guard bounds.contains(rect) else {
            throw HelperFailure(code: "UI_REGION_MULTI_DISPLAY_UNSUPPORTED", message: "Cross-display region capture requires macOS 15.2 or newer")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayId }) else {
            throw HelperFailure(code: "UI_DISPLAY_NOT_FOUND", message: "Display \(displayId) is not shareable")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let localRect = CGRect(x: rect.minX - bounds.minX, y: rect.minY - bounds.minY, width: rect.width, height: rect.height)
        config.sourceRect = localRect
        let backing = appKitScreen(displayId: displayId)?.backingScaleFactor ?? 2.0
        config.width = max(1, Int(rect.width * backing))
        config.height = max(1, Int(rect.height * backing))
        config.showsCursor = includeCursor
        config.capturesAudio = false
        image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    let result = try scaledImage(image, maxWidth: maxWidth, maxHeight: maxHeight)
    var target: [String: Any] = ["kind": "region", "region": rectDictionary(rect)]
    target.merge(displayRouting(for: rect)) { current, _ in current }
    return NativeCapture(image: result, target: target)
}

@available(macOS 14.0, *)
func captureNativeTarget(_ input: [String: Any]) async throws -> NativeCapture {
    let maxWidth = max(64, min(8_192, try intValue(input, "max_width", default: 1_600)))
    let maxHeight = max(64, min(8_192, try intValue(input, "max_height", default: 1_600)))
    let includeCursor = boolValue(input, "include_cursor", default: false)
    let target = (input["target"] as? String)?.lowercased()
        ?? (input["window_id"] != nil ? "window" : (input["region"] != nil ? "region" : "display"))

    switch target {
    case "display":
        let displayId = CGDirectDisplayID(try intValue(input, "display_id", default: Int(CGMainDisplayID())))
        let image = try await captureDisplay(displayId: displayId, maxWidth: maxWidth, maxHeight: maxHeight, includeCursor: includeCursor)
        let bounds = try canonicalDisplayBounds(displayId)
        return NativeCapture(image: image, target: [
            "kind": "display",
            "displayId": Int(displayId),
            "bounds": rectDictionary(bounds),
        ])
    case "window":
        let windowId = CGWindowID(try intValue(input, "window_id"))
        return try await captureWindow(windowId: windowId, maxWidth: maxWidth, maxHeight: maxHeight, includeCursor: includeCursor)
    case "region":
        guard let raw = input["region"] as? [String: Any] else {
            throw HelperFailure(code: "UI_INVALID_INPUT", message: "region target requires a region object")
        }
        let displayId = (input["display_id"] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        let rect = try rectFromDictionary(raw, displayId: displayId)
        return try await captureRegion(rect, maxWidth: maxWidth, maxHeight: maxHeight, includeCursor: includeCursor)
    default:
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "target must be display, window, or region")
    }
}

func encodedCaptureDictionary(_ capture: NativeCapture, format: String, quality: Double) throws -> [String: Any] {
    let encoded = try encodeImage(capture.image, format: format, quality: quality)
    return [
        "mimeType": encoded.0,
        "data": encoded.1.base64EncodedString(),
        "width": capture.image.width,
        "height": capture.image.height,
        "target": capture.target,
    ]
}

// MARK: - OCR

func recognizeText(_ image: CGImage, input: [String: Any]) throws -> [String: Any] {
    let request = VNRecognizeTextRequest()
    let level = (input["recognition_level"] as? String)?.lowercased() ?? "accurate"
    request.recognitionLevel = level == "fast" ? .fast : .accurate
    request.usesLanguageCorrection = boolValue(input, "language_correction", default: true)
    if let languages = input["languages"] as? [String], !languages.isEmpty {
        request.recognitionLanguages = languages
    } else if #available(macOS 13.0, *) {
        request.automaticallyDetectsLanguage = boolValue(input, "automatic_language_detection", default: true)
    }
    if let minimum = input["minimum_text_height"] as? NSNumber {
        request.minimumTextHeight = Float(max(0, min(1, minimum.doubleValue)))
    }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = request.results ?? []
    var blocks: [[String: Any]] = observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        let pixelRect = CGRect(
            x: box.minX * Double(image.width),
            y: (1.0 - box.maxY) * Double(image.height),
            width: box.width * Double(image.width),
            height: box.height * Double(image.height)
        )
        return [
            "text": candidate.string,
            "confidence": Double(candidate.confidence),
            "bounds": rectDictionary(pixelRect),
            "normalizedBounds": rectDictionary(box),
        ]
    }
    blocks.sort {
        let a = $0["bounds"] as? [String: Any] ?? [:]
        let b = $1["bounds"] as? [String: Any] ?? [:]
        let ay = (a["y"] as? NSNumber)?.doubleValue ?? 0
        let by = (b["y"] as? NSNumber)?.doubleValue ?? 0
        if abs(ay - by) > 8 { return ay < by }
        return ((a["x"] as? NSNumber)?.doubleValue ?? 0) < ((b["x"] as? NSNumber)?.doubleValue ?? 0)
    }
    return [
        "fullText": blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"),
        "blocks": blocks,
        "blockCount": blocks.count,
        "imageWidth": image.width,
        "imageHeight": image.height,
        "recognitionLevel": level,
    ]
}

// MARK: - Visual diff / wait

func grayscaleThumbnail(_ image: CGImage, width: Int = 64, height: Int = 64) throws -> [UInt8] {
    var bytes = Array(repeating: UInt8(0), count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let base = raw.baseAddress,
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else {
        throw HelperFailure(code: "UI_IMAGE_DIFF_FAILED", message: "Could not create image-diff thumbnail")
    }
    return bytes
}

func imageDifference(_ lhs: CGImage, _ rhs: CGImage) throws -> [String: Double] {
    let a = try grayscaleThumbnail(lhs)
    let b = try grayscaleThumbnail(rhs)
    guard a.count == b.count, !a.isEmpty else {
        throw HelperFailure(code: "UI_IMAGE_DIFF_FAILED", message: "Image thumbnails are incompatible")
    }
    var sum = 0.0
    var changed = 0
    for i in a.indices {
        let delta = abs(Int(a[i]) - Int(b[i]))
        sum += Double(delta) / 255.0
        if delta >= 16 { changed += 1 }
    }
    return [
        "meanDifference": sum / Double(a.count),
        "changedFraction": Double(changed) / Double(a.count),
    ]
}

@available(macOS 14.0, *)
func waitForVisualCondition(_ input: [String: Any]) async throws -> [String: Any] {
    let timeoutMs = max(100, min(120_000, try intValue(input, "timeout_ms", default: 15_000)))
    let intervalMs = max(50, min(5_000, try intValue(input, "interval_ms", default: 250)))
    let threshold = max(0.0001, min(1.0, try doubleValue(input, "threshold", default: 0.02)))
    let changedFractionThreshold = max(0.0001, min(1.0, try doubleValue(input, "changed_fraction", default: 0.02)))
    let condition = try stringValue(input, "condition", default: "changed").lowercased()
    let stableMs = max(intervalMs, min(timeoutMs, try intValue(input, "stable_ms", default: 750)))
    let started = Date()
    let baseline = try await captureNativeTarget(input)
    var previous = baseline
    var stableSince: Date? = condition == "stable" ? Date() : nil
    var checks = 0
    var metrics: [String: Double] = ["meanDifference": 0, "changedFraction": 0]
    var final = baseline

    waitLoop: while Date().timeIntervalSince(started) * 1000 < Double(timeoutMs) {
        try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        final = try await captureNativeTarget(input)
        checks += 1
        switch condition {
        case "changed":
            metrics = try imageDifference(baseline.image, final.image)
            if (metrics["meanDifference"] ?? 0) >= threshold || (metrics["changedFraction"] ?? 0) >= changedFractionThreshold {
                break waitLoop
            }
        case "stable":
            metrics = try imageDifference(previous.image, final.image)
            let unchanged = (metrics["meanDifference"] ?? 1) < threshold && (metrics["changedFraction"] ?? 1) < changedFractionThreshold
            if unchanged {
                if stableSince == nil { stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) * 1000 >= Double(stableMs) { break waitLoop }
            } else {
                stableSince = nil
            }
            previous = final
        default:
            throw HelperFailure(code: "UI_INVALID_INPUT", message: "visual condition must be changed or stable")
        }
        if Date().timeIntervalSince(started) * 1000 >= Double(timeoutMs) {
            return [
                "matched": false,
                "timedOut": true,
                "condition": condition,
                "checks": checks,
                "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
                "metrics": metrics,
                "target": final.target,
            ]
        }
    }
    var result: [String: Any] = [
        "matched": true,
        "timedOut": false,
        "condition": condition,
        "checks": checks,
        "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
        "metrics": metrics,
        "target": final.target,
    ]
    if boolValue(input, "include_screenshot", default: false) {
        let format = try stringValue(input, "format", default: "jpeg")
        let quality = try doubleValue(input, "quality", default: 0.72)
        let encoded = try encodeImage(final.image, format: format, quality: quality)
        result["mimeType"] = encoded.0
        result["data"] = encoded.1.base64EncodedString()
        result["width"] = final.image.width
        result["height"] = final.image.height
    }
    return result
}

// MARK: - AX selection / waiting / assertions

struct AXLocatedElement {
    let element: AXUIElement
    let path: [Int]
}

func axElementValueString(_ element: AXUIElement) -> String? {
    boundedString(axCopy(element, kAXValueAttribute as CFString), max: 16_000)
}

func stringMatches(_ actual: String, expected: String, caseSensitive: Bool) -> Bool {
    caseSensitive ? actual == expected : actual.caseInsensitiveCompare(expected) == .orderedSame
}

func stringContains(_ actual: String, expected: String, caseSensitive: Bool) -> Bool {
    if caseSensitive { return actual.contains(expected) }
    return actual.range(of: expected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

func axElementMatches(_ element: AXUIElement, selector: [String: Any]) -> Bool {
    let caseSensitive = boolValue(selector, "case_sensitive", default: false)
    let fields: [(String, CFString)] = [
        ("role", kAXRoleAttribute as CFString),
        ("subrole", kAXSubroleAttribute as CFString),
        ("title", kAXTitleAttribute as CFString),
        ("identifier", kAXIdentifierAttribute as CFString),
        ("description", kAXDescriptionAttribute as CFString),
        ("value", kAXValueAttribute as CFString),
    ]
    for (key, attr) in fields {
        if let expected = selector[key] as? String {
            let actual = key == "value" ? (axElementValueString(element) ?? "") : (axString(element, attr) ?? "")
            if !stringMatches(actual, expected: expected, caseSensitive: caseSensitive) { return false }
        }
        if let expected = selector["\(key)_contains"] as? String {
            let actual = key == "value" ? (axElementValueString(element) ?? "") : (axString(element, attr) ?? "")
            if !stringContains(actual, expected: expected, caseSensitive: caseSensitive) { return false }
        }
    }
    if let expected = (selector["enabled"] as? NSNumber)?.boolValue,
       axBool(element, kAXEnabledAttribute as CFString) != expected { return false }
    if let expected = (selector["focused"] as? NSNumber)?.boolValue,
       axBool(element, kAXFocusedAttribute as CFString) != expected { return false }
    return true
}

func findAXElement(pid: pid_t, selector: [String: Any], maxDepth: Int, maxElements: Int) -> AXLocatedElement? {
    let root = AXUIElementCreateApplication(pid)
    var visited = 0
    func walk(_ element: AXUIElement, path: [Int], depth: Int) -> AXLocatedElement? {
        guard visited < maxElements else { return nil }
        visited += 1
        if axElementMatches(element, selector: selector) { return AXLocatedElement(element: element, path: path) }
        guard depth < maxDepth else { return nil }
        for (index, child) in axChildren(element).enumerated() {
            if let found = walk(child, path: path + [index], depth: depth + 1) { return found }
            if visited >= maxElements { break }
        }
        return nil
    }
    return walk(root, path: [], depth: 0)
}

func findPathToElement(pid: pid_t, target: AXUIElement, maxDepth: Int = 8, maxElements: Int = 2_000) -> [Int]? {
    let root = AXUIElementCreateApplication(pid)
    var visited = 0
    func walk(_ element: AXUIElement, path: [Int], depth: Int) -> [Int]? {
        guard visited < maxElements else { return nil }
        visited += 1
        if CFEqual(element, target) { return path }
        guard depth < maxDepth else { return nil }
        for (index, child) in axChildren(element).enumerated() {
            if let found = walk(child, path: path + [index], depth: depth + 1) { return found }
        }
        return nil
    }
    return walk(root, path: [], depth: 0)
}

func resolveRefLenient(_ ref: String) throws -> (pid_t, AXUIElement, [Int]) {
    let (pid, path, fingerprint) = try parseRef(ref)
    let element = try elementAtPath(pid: pid, path: path, expectedFingerprint: fingerprint)
    return (pid, element, path)
}

func conditionMatches(element: AXUIElement?, condition: String, expected: Any?) -> Bool {
    switch condition {
    case "exists": return element != nil
    case "not_exists": return element == nil
    default: break
    }
    guard let element else { return false }
    switch condition {
    case "focused":
        let value = (expected as? NSNumber)?.boolValue ?? true
        return axBool(element, kAXFocusedAttribute as CFString) == value
    case "enabled":
        let value = (expected as? NSNumber)?.boolValue ?? true
        return axBool(element, kAXEnabledAttribute as CFString) == value
    case "value_equals":
        return axElementValueString(element) == (expected as? String ?? "")
    case "value_contains":
        return (axElementValueString(element) ?? "").contains(expected as? String ?? "")
    case "title_equals":
        return axString(element, kAXTitleAttribute as CFString) == (expected as? String ?? "")
    case "title_contains":
        return (axString(element, kAXTitleAttribute as CFString) ?? "").contains(expected as? String ?? "")
    default:
        return false
    }
}

func evaluateAXCondition(_ input: [String: Any], pid: pid_t) throws -> (Bool, AXLocatedElement?) {
    let condition = try stringValue(input, "condition", default: "exists").lowercased()
    let expected = input["expected"]
    let located: AXLocatedElement?
    if let ref = input["ref"] as? String {
        do {
            let (_, element, path) = try resolveRefLenient(ref)
            located = AXLocatedElement(element: element, path: path)
        } catch let failure as HelperFailure where failure.code == "UI_ELEMENT_STALE" {
            located = nil
        }
    } else {
        let selector = input["selector"] as? [String: Any] ?? [:]
        let maxDepth = max(0, min(20, (input["max_depth"] as? NSNumber)?.intValue ?? 10))
        let maxElements = max(1, min(10_000, (input["max_elements"] as? NSNumber)?.intValue ?? 2_000))
        located = findAXElement(pid: pid, selector: selector, maxDepth: maxDepth, maxElements: maxElements)
    }
    return (conditionMatches(element: located?.element, condition: condition, expected: expected), located)
}

final class AXWakeBox {
    var notifications = 0
}

let axWakeCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<AXWakeBox>.fromOpaque(refcon).takeUnretainedValue().notifications += 1
}

func waitForAXCondition(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let pid = try targetPid(input)
    let timeoutMs = max(0, min(120_000, try intValue(input, "timeout_ms", default: 15_000)))
    let pollMs = max(25, min(5_000, try intValue(input, "poll_interval_ms", default: 250)))
    let app = AXUIElementCreateApplication(pid)
    let box = AXWakeBox()
    let opaque = Unmanaged.passUnretained(box).toOpaque()
    var observer: AXObserver?
    var source: CFRunLoopSource?
    var registered = 0
    if AXObserverCreate(pid, axWakeCallback, &observer) == .success, let observer {
        source = AXObserverGetRunLoopSource(observer)
        if let source { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode) }
        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXValueChangedNotification as CFString,
            kAXTitleChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            "AXLayoutChanged" as CFString,
        ]
        for notification in notifications {
            let result = AXObserverAddNotification(observer, app, notification, opaque)
            if result == .success || result == .notificationAlreadyRegistered { registered += 1 }
        }
    }
    defer {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode) }
    }

    let started = Date()
    var checks = 0
    while true {
        checks += 1
        let evaluated = try evaluateAXCondition(input, pid: pid)
        if evaluated.0 {
            var result: [String: Any] = [
                "matched": true,
                "timedOut": false,
                "pid": Int(pid),
                "condition": (input["condition"] as? String) ?? "exists",
                "checks": checks,
                "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
                "observerRegistrations": registered,
                "observerNotifications": box.notifications,
            ]
            if let located = evaluated.1 {
                result["element"] = describeAXElement(located.element, pid: pid, path: located.path, includeValue: true)
            }
            return result
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if elapsed >= timeoutMs {
            return [
                "matched": false,
                "timedOut": true,
                "pid": Int(pid),
                "condition": (input["condition"] as? String) ?? "exists",
                "checks": checks,
                "elapsedMs": elapsed,
                "observerRegistrations": registered,
                "observerNotifications": box.notifications,
            ]
        }
        let remaining = max(1, timeoutMs - elapsed)
        let slice = min(pollMs, remaining)
        if registered > 0 {
            CFRunLoopRunInMode(.defaultMode, Double(slice) / 1000.0, true)
        } else {
            Thread.sleep(forTimeInterval: Double(slice) / 1000.0)
        }
    }
}

func assertAXCondition(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let pid = try targetPid(input)
    let evaluated = try evaluateAXCondition(input, pid: pid)
    guard evaluated.0 else {
        throw HelperFailure(code: "UI_ASSERTION_FAILED", message: "Accessibility assertion did not match current UI state")
    }
    var result: [String: Any] = ["matched": true, "pid": Int(pid)]
    if let located = evaluated.1 {
        result["element"] = describeAXElement(located.element, pid: pid, path: located.path, includeValue: true)
    }
    return result
}

// MARK: - Window mapping and actions

struct CGWindowRecord {
    let windowId: CGWindowID
    let ownerPid: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
}

func cgWindowRecord(windowId: CGWindowID) -> CGWindowRecord? {
    guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], windowId) as? [[String: Any]],
          let window = raw.first else { return nil }
    let boundsRaw = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    var rect = CGRect.zero
    CGRectMakeWithDictionaryRepresentation(boundsRaw as CFDictionary, &rect)
    return CGWindowRecord(
        windowId: windowId,
        ownerPid: pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0),
        ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
        title: window[kCGWindowName as String] as? String ?? "",
        bounds: rect
    )
}

func axWindowsForPid(_ pid: pid_t) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    return (axCopy(app, kAXWindowsAttribute as CFString) as? [AXUIElement]) ?? []
}

func waitForAXWindows(pid: pid_t, timeoutMs: Int = 1_500) -> [AXUIElement] {
    let deadline = Date().addingTimeInterval(Double(max(0, timeoutMs)) / 1000.0)
    repeat {
        let windows = axWindowsForPid(pid)
        if !windows.isEmpty { return windows }
        CFRunLoopRunInMode(.defaultMode, 0.04, false)
    } while Date() < deadline
    return axWindowsForPid(pid)
}

func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> Double {
    abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axPoint(element, kAXPositionAttribute as CFString), let s = axSize(element, kAXSizeAttribute as CFString) else { return nil }
    return CGRect(origin: p, size: s)
}

func resolveAXWindow(_ input: [String: Any]) throws -> (pid_t, AXUIElement, [Int]) {
    try requireAccessibility()
    if let ref = input["ref"] as? String {
        let (pid, element, path) = try resolveRefLenient(ref)
        return (pid, element, path)
    }
    if let number = input["window_id"] as? NSNumber {
        let windowId = CGWindowID(number.uint32Value)
        guard let record = cgWindowRecord(windowId: windowId), record.ownerPid > 0 else {
            throw HelperFailure(code: "UI_WINDOW_NOT_FOUND", message: "Window \(windowId) no longer exists")
        }
        let windows = waitForAXWindows(pid: record.ownerPid)
        guard !windows.isEmpty else {
            throw HelperFailure(code: "UI_WINDOW_AX_UNAVAILABLE", message: "No Accessibility windows are exposed for window \(windowId)")
        }
        let ranked = windows.sorted { lhs, rhs in
            func score(_ element: AXUIElement) -> Double {
                var score = axFrame(element).map { frameDistance($0, record.bounds) } ?? 100_000
                let title = axString(element, kAXTitleAttribute as CFString) ?? ""
                if !record.title.isEmpty && title == record.title { score -= 10_000 }
                return score
            }
            return score(lhs) < score(rhs)
        }
        guard let window = ranked.first else {
            throw HelperFailure(code: "UI_WINDOW_AX_UNAVAILABLE", message: "Could not map CoreGraphics window to Accessibility")
        }
        let path = findPathToElement(pid: record.ownerPid, target: window) ?? []
        return (record.ownerPid, window, path)
    }
    let pid = try targetPid(input)
    let app = AXUIElementCreateApplication(pid)
    if let focused = axCopy(app, kAXFocusedWindowAttribute as CFString), CFGetTypeID(focused) == AXUIElementGetTypeID() {
        let window = focused as! AXUIElement
        return (pid, window, findPathToElement(pid: pid, target: window) ?? [])
    }
    guard let window = waitForAXWindows(pid: pid).first else {
        throw HelperFailure(code: "UI_WINDOW_NOT_FOUND", message: "No Accessibility window is available for pid \(pid)")
    }
    return (pid, window, findPathToElement(pid: pid, target: window) ?? [])
}

func axSetPoint(_ element: AXUIElement, attribute: CFString, point: CGPoint) -> AXError {
    var value = point
    guard let axValue = AXValueCreate(.cgPoint, &value) else { return .illegalArgument }
    return AXUIElementSetAttributeValue(element, attribute, axValue)
}

func axSetSize(_ element: AXUIElement, attribute: CFString, size: CGSize) -> AXError {
    var value = size
    guard let axValue = AXValueCreate(.cgSize, &value) else { return .illegalArgument }
    return AXUIElementSetAttributeValue(element, attribute, axValue)
}

func windowState(pid: pid_t, window: AXUIElement, path: [Int]) -> [String: Any] {
    var result = describeAXElement(window, pid: pid, path: path, includeValue: false)
    if let frame = axFrame(window) {
        result["frame"] = rectDictionary(frame)
        result.merge(displayRouting(for: frame)) { current, _ in current }
    }
    if let minimized = axBool(window, kAXMinimizedAttribute as CFString) { result["minimized"] = minimized }
    if let main = axBool(window, kAXMainAttribute as CFString) { result["main"] = main }
    if let fullScreen = axBool(window, "AXFullScreen" as CFString) { result["fullScreen"] = fullScreen }
    return result
}

func performWindowAction(_ input: [String: Any]) throws -> [String: Any] {
    let (pid, window, path) = try resolveAXWindow(input)
    let action = try stringValue(input, "action").lowercased()
    let app = NSRunningApplication(processIdentifier: pid)
    func requireSuccess(_ error: AXError, _ what: String) throws {
        guard error == .success else {
            throw HelperFailure(code: "UI_WINDOW_ACTION_FAILED", message: "\(what) failed with AX error \(error.rawValue)")
        }
    }

    switch action {
    case "focus", "raise":
        _ = app?.activate(options: [.activateIgnoringOtherApps])
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raised != .success {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    case "move":
        let point = CGPoint(x: try doubleValue(input, "x"), y: try doubleValue(input, "y"))
        try requireSuccess(axSetPoint(window, attribute: kAXPositionAttribute as CFString, point: point), "move")
    case "resize":
        let size = CGSize(width: try doubleValue(input, "width"), height: try doubleValue(input, "height"))
        guard size.width > 0, size.height > 0 else { throw HelperFailure(code: "UI_INVALID_INPUT", message: "window size must be positive") }
        try requireSuccess(axSetSize(window, attribute: kAXSizeAttribute as CFString, size: size), "resize")
    case "set_bounds":
        let point = CGPoint(x: try doubleValue(input, "x"), y: try doubleValue(input, "y"))
        let size = CGSize(width: try doubleValue(input, "width"), height: try doubleValue(input, "height"))
        guard size.width > 0, size.height > 0 else { throw HelperFailure(code: "UI_INVALID_INPUT", message: "window size must be positive") }
        try requireSuccess(axSetPoint(window, attribute: kAXPositionAttribute as CFString, point: point), "set_bounds position")
        try requireSuccess(axSetSize(window, attribute: kAXSizeAttribute as CFString, size: size), "set_bounds size")
    case "minimize":
        try requireSuccess(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue), "minimize")
    case "restore", "unminimize":
        try requireSuccess(AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse), "restore")
        _ = app?.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    case "fullscreen", "enter_fullscreen", "exit_fullscreen":
        let desired = action != "exit_fullscreen"
        let direct = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, desired ? kCFBooleanTrue : kCFBooleanFalse)
        if direct != .success {
            let current = axBool(window, "AXFullScreen" as CFString)
            if current != desired,
               let button = axCopy(window, kAXFullScreenButtonAttribute as CFString),
               CFGetTypeID(button) == AXUIElementGetTypeID() {
                try requireSuccess(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString), "full-screen button")
            } else if current == nil {
                throw HelperFailure(code: "UI_WINDOW_ACTION_FAILED", message: "Application does not expose a controllable full-screen state")
            }
        }
    case "close":
        guard let button = axCopy(window, kAXCloseButtonAttribute as CFString), CFGetTypeID(button) == AXUIElementGetTypeID() else {
            throw HelperFailure(code: "UI_WINDOW_ACTION_FAILED", message: "Window does not expose a close button")
        }
        try requireSuccess(AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString), "close")
    default:
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "Unsupported window action '\(action)'")
    }
    Thread.sleep(forTimeInterval: min(0.25, max(0.02, (input["settle_ms"] as? NSNumber)?.doubleValue ?? 80) / 1000.0))
    return ["performed": true, "action": action, "pid": Int(pid), "window": windowState(pid: pid, window: window, path: path)]
}

// MARK: - Drag/drop and richer pointer control

func centerOfRef(_ ref: String) throws -> CGPoint {
    let (_, element, _) = try resolveRefLenient(ref)
    guard let frame = axFrame(element) else {
        throw HelperFailure(code: "UI_ELEMENT_NO_FRAME", message: "Accessibility element has no screen frame")
    }
    return CGPoint(x: frame.midX, y: frame.midY)
}

func performDrag(from: CGPoint, to: CGPoint, durationMs: Int, button: CGMouseButton = .left) throws {
    let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let dragType: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
    let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: from, mouseButton: button) else {
        throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create drag start event")
    }
    down.post(tap: .cghidEventTap)
    let steps = max(2, min(120, durationMs / 12))
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        guard let drag = CGEvent(mouseEventSource: nil, mouseType: dragType, mouseCursorPosition: point, mouseButton: button) else {
            throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create drag event")
        }
        drag.post(tap: .cghidEventTap)
        if durationMs > 0 { usleep(useconds_t(max(1, durationMs * 1_000 / steps))) }
    }
    guard let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: to, mouseButton: button) else {
        throw HelperFailure(code: "UI_INPUT_EVENT_FAILED", message: "Could not create drag end event")
    }
    up.post(tap: .cghidEventTap)
}

func performDragDrop(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let from: CGPoint
    let to: CGPoint
    if let ref = input["source_ref"] as? String { from = try centerOfRef(ref) }
    else { from = try globalPoint(input, prefix: "from") }
    if let ref = input["destination_ref"] as? String { to = try centerOfRef(ref) }
    else { to = try globalPoint(input, prefix: "to") }
    let duration = max(0, min(10_000, try intValue(input, "duration_ms", default: 450)))
    let button: CGMouseButton = ((input["button"] as? String)?.lowercased() == "right") ? .right : .left
    try performDrag(from: from, to: to, durationMs: duration, button: button)
    return ["performed": true, "from": ["x": from.x, "y": from.y], "to": ["x": to.x, "y": to.y], "durationMs": duration]
}

// MARK: - Native dialogs / file pickers

func collectDialogElements(pid: pid_t, maxElements: Int = 2_000) -> [AXLocatedElement] {
    let root = AXUIElementCreateApplication(pid)
    var result: [AXLocatedElement] = []
    var visited = 0
    func walk(_ element: AXUIElement, path: [Int], depth: Int) {
        guard visited < maxElements, depth <= 12 else { return }
        visited += 1
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = axString(element, kAXSubroleAttribute as CFString) ?? ""
        if role == (kAXSheetRole as String) || subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String) {
            result.append(AXLocatedElement(element: element, path: path))
        }
        for (index, child) in axChildren(element).enumerated() {
            walk(child, path: path + [index], depth: depth + 1)
            if visited >= maxElements { break }
        }
    }
    walk(root, path: [], depth: 0)
    return result
}

func buttonSummaries(_ root: AXUIElement, pid: pid_t, rootPath: [Int], maxElements: Int = 500) -> [[String: Any]] {
    var result: [[String: Any]] = []
    var visited = 0
    func walk(_ element: AXUIElement, path: [Int], depth: Int) {
        guard visited < maxElements, depth <= 8 else { return }
        visited += 1
        if axString(element, kAXRoleAttribute as CFString) == (kAXButtonRole as String) {
            result.append(describeAXElement(element, pid: pid, path: path, includeValue: false))
        }
        for (index, child) in axChildren(element).enumerated() {
            walk(child, path: path + [index], depth: depth + 1)
        }
    }
    walk(root, path: rootPath, depth: 0)
    return result
}

func dialogList(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let pid = try targetPid(input)
    let dialogs = collectDialogElements(pid: pid)
    let values = dialogs.map { located -> [String: Any] in
        var item = describeAXElement(located.element, pid: pid, path: located.path, includeValue: false)
        item["buttons"] = buttonSummaries(located.element, pid: pid, rootPath: located.path)
        return item
    }
    return ["pid": Int(pid), "dialogs": values, "count": values.count]
}

func resolveDialog(_ input: [String: Any]) throws -> (pid_t, AXLocatedElement) {
    if let ref = input["dialog_ref"] as? String {
        let (pid, element, path) = try resolveRefLenient(ref)
        return (pid, AXLocatedElement(element: element, path: path))
    }
    let pid = try targetPid(input)
    let dialogs = collectDialogElements(pid: pid)
    if let title = input["dialog_title"] as? String {
        if let found = dialogs.first(where: { stringMatches(axString($0.element, kAXTitleAttribute as CFString) ?? "", expected: title, caseSensitive: false) }) {
            return (pid, found)
        }
    }
    guard let first = dialogs.first else {
        throw HelperFailure(code: "UI_DIALOG_NOT_FOUND", message: "No native dialog or sheet is exposed for pid \(pid)")
    }
    return (pid, first)
}

func performDialogAction(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let (pid, dialog) = try resolveDialog(input)
    let action = try stringValue(input, "action", default: "default").lowercased()
    let target: AXUIElement
    switch action {
    case "default":
        guard let raw = axCopy(dialog.element, kAXDefaultButtonAttribute as CFString), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw HelperFailure(code: "UI_DIALOG_BUTTON_NOT_FOUND", message: "Dialog has no default button")
        }
        target = raw as! AXUIElement
    case "cancel":
        if let raw = axCopy(dialog.element, kAXCancelButtonAttribute as CFString), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            target = raw as! AXUIElement
        } else {
            _ = try postKeyboard(["key": "escape"])
            return ["performed": true, "action": "cancel", "pid": Int(pid), "via": "escape"]
        }
    case "button":
        let title = try stringValue(input, "button_title")
        let selector: [String: Any] = ["role": kAXButtonRole as String, "title": title]
        guard let found = findAXElement(pid: pid, selector: selector, maxDepth: 14, maxElements: 3_000) else {
            throw HelperFailure(code: "UI_DIALOG_BUTTON_NOT_FOUND", message: "Button '\(title)' was not found")
        }
        target = found.element
    default:
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "dialog action must be default, cancel, or button")
    }
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard result == .success else {
        throw HelperFailure(code: "UI_DIALOG_ACTION_FAILED", message: "Dialog button press failed with AX error \(result.rawValue)")
    }
    return ["performed": true, "action": action, "pid": Int(pid)]
}

func findAXDescendant(_ root: AXUIElement, selector: [String: Any], maxDepth: Int = 12, maxElements: Int = 2_000) -> AXUIElement? {
    var visited = 0
    func walk(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard visited < maxElements else { return nil }
        visited += 1
        if axElementMatches(element, selector: selector) { return element }
        guard depth < maxDepth else { return nil }
        for child in axChildren(element) {
            if let found = walk(child, depth: depth + 1) { return found }
            if visited >= maxElements { break }
        }
        return nil
    }
    return walk(root, depth: 0)
}

func waitForAXDescendant(_ root: AXUIElement, selector: [String: Any], timeoutMs: Int, maxDepth: Int = 12, maxElements: Int = 2_000) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let found = findAXDescendant(root, selector: selector, maxDepth: maxDepth, maxElements: maxElements) { return found }
        CFRunLoopRunInMode(.defaultMode, 0.04, false)
    } while Date() < deadline
    return nil
}

func currentFilePanel(pid: pid_t) -> AXUIElement? {
    for window in axWindowsForPid(pid) {
        for child in axChildren(window) {
            let role = axString(child, kAXRoleAttribute as CFString) ?? ""
            guard role == (kAXSheetRole as String) else { continue }
            let identifier = axString(child, kAXIdentifierAttribute as CFString) ?? ""
            let description = axString(child, kAXDescriptionAttribute as CFString) ?? ""
            if identifier == "open-panel" || identifier == "save-panel" || description == "open" || description == "save" {
                return child
            }
        }
    }
    return nil
}

func waitForFilePanel(pid: pid_t, timeoutMs: Int) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let panel = currentFilePanel(pid: pid) { return panel }
        CFRunLoopRunInMode(.defaultMode, 0.04, false)
    } while Date() < deadline
    return nil
}

func currentFilePanelButton(pid: pid_t) -> AXUIElement? {
    guard let panel = currentFilePanel(pid: pid) else { return nil }
    // On current AppKit the Open/Save button is a direct sheet child. Keep a
    // shallow fallback for minor OS layout changes without walking the file list.
    if let direct = axChildren(panel).first(where: { axString($0, kAXIdentifierAttribute as CFString) == "OKButton" }) {
        return direct
    }
    return findAXDescendant(panel, selector: ["identifier": "OKButton"], maxDepth: 3, maxElements: 120)
}

func currentFilePanelElement(pid: pid_t, identifier: String) -> AXUIElement? {
    guard let panel = currentFilePanel(pid: pid) else { return nil }
    if let direct = axChildren(panel).first(where: { axString($0, kAXIdentifierAttribute as CFString) == identifier }) {
        return direct
    }
    return findAXDescendant(panel, selector: ["identifier": identifier], maxDepth: 6, maxElements: 300)
}

func waitForFilePanelElement(pid: pid_t, identifier: String, timeoutMs: Int) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if let element = currentFilePanelElement(pid: pid, identifier: identifier) { return element }
        CFRunLoopRunInMode(.defaultMode, 0.04, false)
    } while Date() < deadline
    return nil
}

func waitForFilePanelElementGone(pid: pid_t, identifier: String, timeoutMs: Int) -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    repeat {
        if currentFilePanelElement(pid: pid, identifier: identifier) == nil { return true }
        CFRunLoopRunInMode(.defaultMode, 0.04, false)
    } while Date() < deadline
    return currentFilePanelElement(pid: pid, identifier: identifier) == nil
}

func performFileDialog(_ input: [String: Any]) throws -> [String: Any] {
    try requireAccessibility()
    let pid = try targetPid(input)
    let path = try stringValue(input, "path")
    guard path.hasPrefix("/") else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "file-dialog path must be absolute")
    }
    let mode = try stringValue(input, "mode", default: "open").lowercased()
    guard ["open", "save"].contains(mode) else {
        throw HelperFailure(code: "UI_INVALID_INPUT", message: "file-dialog mode must be open or save")
    }
    if mode == "open" && !FileManager.default.fileExists(atPath: path) {
        throw HelperFailure(code: "UI_FILE_NOT_FOUND", message: "Open-dialog path does not exist: \(path)")
    }
    let requireDialog = boolValue(input, "require_dialog", default: true)
    if requireDialog && waitForFilePanel(pid: pid, timeoutMs: 2_000) == nil {
        throw HelperFailure(code: "UI_DIALOG_NOT_FOUND", message: "No native NSOpenPanel/NSSavePanel is visible for the target application")
    }
    if let app = NSRunningApplication(processIdentifier: pid) { _ = app.activate(options: [.activateIgnoringOtherApps]) }
    Thread.sleep(forTimeInterval: 0.08)

    let navigationPath: String
    let saveName: String?
    if mode == "save" {
        navigationPath = (path as NSString).deletingLastPathComponent
        saveName = (path as NSString).lastPathComponent
    } else {
        navigationPath = path
        saveName = nil
    }

    // Open Apple's standard Go-to-Folder sheet. App activation and key-equivalent
    // delivery are asynchronous, so retry a bounded number of times and recognize
    // success by the actual AX PathTextField, not by foreground assumptions.
    var pathField: AXUIElement?
    for _ in 0..<3 {
        if let existing = currentFilePanelElement(pid: pid, identifier: "PathTextField") {
            pathField = existing
            break
        }
        if let app = NSRunningApplication(processIdentifier: pid) { _ = app.activate(options: [.activateIgnoringOtherApps]) }
        Thread.sleep(forTimeInterval: 0.10)
        _ = try postKeyboard(["key": "g", "modifiers": ["command", "shift"]])
        if let opened = waitForFilePanelElement(pid: pid, identifier: "PathTextField", timeoutMs: 900) {
            pathField = opened
            break
        }
    }
    guard pathField != nil else {
        throw HelperFailure(code: "UI_FILE_DIALOG_NAVIGATION_FAILED", message: "Go-to-Folder path field did not appear after bounded shortcut retries")
    }

    // A focus change is not proof that Go-to-Folder committed: autocomplete rows can
    // take focus while the nested sheet remains open. Re-resolve the live field on
    // every attempt and accept navigation only when PathTextField actually disappears.
    var navigationAccepted = false
    for _ in 0..<3 where !navigationAccepted {
        guard let liveField = currentFilePanelElement(pid: pid, identifier: "PathTextField") else {
            navigationAccepted = true
            break
        }
        let setPath = AXUIElementSetAttributeValue(liveField, kAXValueAttribute as CFString, navigationPath as CFTypeRef)
        guard setPath == .success else {
            throw HelperFailure(code: "UI_FILE_DIALOG_NAVIGATION_FAILED", message: "Could not set Go-to-Folder path (AX error \(setPath.rawValue))")
        }
        _ = AXUIElementSetAttributeValue(liveField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.08)
        _ = try postKeyboard(["key": "return"])
        navigationAccepted = waitForFilePanelElementGone(pid: pid, identifier: "PathTextField", timeoutMs: 900)
    }
    guard navigationAccepted else {
        throw HelperFailure(code: "UI_FILE_DIALOG_NAVIGATION_FAILED", message: "Go-to-Folder sheet did not accept the requested path after bounded commit retries")
    }
    Thread.sleep(forTimeInterval: 0.10)

    if let saveName {
        guard let field = waitForFilePanelElement(pid: pid, identifier: "saveAsNameTextField", timeoutMs: 1_500) else {
            throw HelperFailure(code: "UI_FILE_DIALOG_FILENAME_FAILED", message: "Save panel filename field was not exposed through Accessibility")
        }
        let set = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, saveName as CFTypeRef)
        guard set == .success else {
            throw HelperFailure(code: "UI_FILE_DIALOG_FILENAME_FAILED", message: "Could not set save filename (AX error \(set.rawValue))")
        }
    }

    let confirm = boolValue(input, "confirm", default: true)
    var confirmed = false
    if confirm {
        // Reacquire the panel after the nested Go-to-Folder sheet closes. AppKit can
        // replace the AX object identity during this transition, so retaining the
        // pre-navigation AXUIElement is not reliable. This lookup scans only window
        // children and the sheet's shallow controls, never the file-list subtree.
        let deadline = Date().addingTimeInterval(3.0)
        var button: AXUIElement?
        repeat {
            button = currentFilePanelButton(pid: pid)
            if button != nil { break }
            // A fully qualified path may close the panel directly.
            if currentFilePanel(pid: pid) == nil {
                confirmed = true
                break
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        } while Date() < deadline

        if !confirmed {
            guard let button else {
                throw HelperFailure(code: "UI_FILE_DIALOG_CONFIRM_FAILED", message: "File dialog Open/Save button did not appear after navigation settled")
            }
            if axBool(button, kAXEnabledAttribute as CFString) == false {
                let enabledDeadline = Date().addingTimeInterval(2.0)
                while Date() < enabledDeadline && axBool(button, kAXEnabledAttribute as CFString) == false {
                    CFRunLoopRunInMode(.defaultMode, 0.04, false)
                }
            }
            guard axBool(button, kAXEnabledAttribute as CFString) != false else {
                throw HelperFailure(code: "UI_FILE_DIALOG_CONFIRM_FAILED", message: "File dialog Open/Save button did not become enabled")
            }
            let press = AXUIElementPerformAction(button, kAXPressAction as CFString)
            guard press == .success else {
                throw HelperFailure(code: "UI_FILE_DIALOG_CONFIRM_FAILED", message: "File dialog confirmation failed with AX error \(press.rawValue)")
            }
            confirmed = true
        }
    }
    return ["performed": true, "pid": Int(pid), "mode": mode, "path": path, "confirmed": confirmed]
}
