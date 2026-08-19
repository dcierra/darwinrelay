import AppKit

final class ColorPanel: NSView {
    var active = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        (active ? NSColor.systemGreen : NSColor.systemGray).setFill()
        dirtyRect.fill()
    }
}

final class FixtureController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var counter = 0
    private let counterLabel = NSTextField(labelWithString: "Counter: 0")
    private let input = NSTextField(string: "initial")
    private let checkbox = NSButton(checkboxWithTitle: "Enabled option", target: nil, action: nil)
    private let slider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let colorPanel = ColorPanel(frame: .zero)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let frame = NSRect(x: 180, y: 180, width: 720, height: 520)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DarwinRelay Desktop Fixture"
        window.setAccessibilityIdentifier("fixture.window")
        window.isReleasedWhenClosed = false

        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x, y: y, width: w, height: h)
            root.addSubview(view)
        }

        let title = NSTextField(labelWithString: "DarwinRelay Desktop Control Fixture")
        title.font = .boldSystemFont(ofSize: 18)
        title.setAccessibilityIdentifier("fixture.title")
        place(title, 28, 458, 520, 28)

        let inputLabel = NSTextField(labelWithString: "Input")
        place(inputLabel, 28, 410, 100, 24)
        input.setAccessibilityIdentifier("fixture.input")
        place(input, 145, 407, 330, 28)

        counterLabel.setAccessibilityIdentifier("fixture.counter")
        place(counterLabel, 28, 360, 190, 28)
        let increment = NSButton(title: "Increment", target: self, action: #selector(incrementCounter))
        increment.bezelStyle = .rounded
        increment.setAccessibilityIdentifier("fixture.increment")
        place(increment, 220, 355, 130, 32)

        checkbox.setAccessibilityIdentifier("fixture.checkbox")
        place(checkbox, 28, 310, 180, 28)

        let sliderLabel = NSTextField(labelWithString: "Slider")
        place(sliderLabel, 28, 266, 90, 24)
        slider.setAccessibilityIdentifier("fixture.slider")
        place(slider, 145, 262, 330, 28)

        let dialog = NSButton(title: "Open Dialog", target: self, action: #selector(openDialog))
        dialog.setAccessibilityIdentifier("fixture.open_dialog")
        place(dialog, 28, 208, 130, 34)

        let file = NSButton(title: "Open File Picker", target: self, action: #selector(openFilePicker))
        file.setAccessibilityIdentifier("fixture.open_file")
        place(file, 175, 208, 155, 34)

        let flash = NSButton(title: "Flash Panel", target: self, action: #selector(flashPanel))
        flash.setAccessibilityIdentifier("fixture.flash")
        place(flash, 347, 208, 130, 34)

        let save = NSButton(title: "Save File Picker", target: self, action: #selector(openSavePicker))
        save.setAccessibilityIdentifier("fixture.save_file")
        place(save, 494, 208, 160, 34)

        colorPanel.setAccessibilityIdentifier("fixture.color_panel")
        place(colorPanel, 28, 112, 449, 72)

        statusLabel.setAccessibilityIdentifier("fixture.status")
        place(statusLabel, 28, 64, 640, 28)

        let quit = NSButton(title: "Quit Fixture", target: self, action: #selector(quitFixture))
        quit.setAccessibilityIdentifier("fixture.quit")
        place(quit, 540, 28, 140, 34)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func incrementCounter() {
        counter += 1
        counterLabel.stringValue = "Counter: \(counter)"
        statusLabel.stringValue = "Incremented"
    }

    @objc private func openDialog() {
        let alert = NSAlert()
        alert.messageText = "Fixture Dialog"
        alert.informativeText = "Native dialog control target"
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.statusLabel.stringValue = response == .alertFirstButtonReturn ? "Dialog confirmed" : "Dialog cancelled"
        }
    }

    @objc private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.statusLabel.stringValue = "Selected: \(url.path)"
            } else {
                self?.statusLabel.stringValue = "File picker cancelled"
            }
        }
    }

    @objc private func openSavePicker() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "fixture-output.txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.statusLabel.stringValue = "Saved: \(url.path)"
            } else {
                self?.statusLabel.stringValue = "Save picker cancelled"
            }
        }
    }

    @objc private func flashPanel() {
        colorPanel.active = true
        statusLabel.stringValue = "Flashing"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.colorPanel.active = false
            self?.statusLabel.stringValue = "Flash complete"
        }
    }

    @objc private func quitFixture() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DesktopControlFixture {
    static func main() {
        let app = NSApplication.shared
        let delegate = FixtureController()
        app.delegate = delegate
        app.run()
    }
}
