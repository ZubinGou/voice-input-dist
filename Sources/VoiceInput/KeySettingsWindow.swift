import AppKit

final class KeySettingsWindow: NSPanel {
    private let triggerKeyLabel = NSTextField(labelWithString: "")
    private let recordKeyButton = NSButton()
    private let holdSlider = NSSlider()
    private let holdValueLabel = NSTextField(labelWithString: "")

    private let keyMonitor: KeyMonitor

    init(keyMonitor: KeyMonitor) {
        self.keyMonitor = keyMonitor
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Key Settings"
        isReleasedWhenClosed = false
        setupUI()
        updateUI()
        center()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: self
        )
    }

    private func setupUI() {
        guard let cv = contentView else { return }

        triggerKeyLabel.isEditable = false
        triggerKeyLabel.isBordered = true
        triggerKeyLabel.bezelStyle = .roundedBezel
        triggerKeyLabel.isSelectable = false
        triggerKeyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        recordKeyButton.title = "Record Key…"
        recordKeyButton.bezelStyle = .rounded
        recordKeyButton.target = self
        recordKeyButton.action = #selector(startRecording)

        let keyRowLabel = NSTextField(labelWithString: "Trigger Key:")
        keyRowLabel.alignment = .right

        let keyRow = NSStackView(views: [triggerKeyLabel, recordKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8

        holdSlider.minValue = 0
        holdSlider.maxValue = 1000
        holdSlider.target = self
        holdSlider.action = #selector(sliderMoved)

        holdValueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        holdValueLabel.textColor = .secondaryLabelColor

        let holdHint = NSTextField(labelWithString: "0 = trigger instantly · ≥100 ms = hold alone to trigger (combos always pass through)")
        holdHint.font = .systemFont(ofSize: 11)
        holdHint.textColor = .tertiaryLabelColor

        let holdRowLabel = NSTextField(labelWithString: "Hold Threshold:")
        holdRowLabel.alignment = .right

        let holdRow = NSStackView(views: [holdSlider, holdValueLabel])
        holdRow.orientation = .horizontal
        holdRow.spacing = 8
        holdSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let holdStack = NSStackView(views: [holdRow, holdHint])
        holdStack.orientation = .vertical
        holdStack.spacing = 2
        holdStack.alignment = .leading

        let grid = NSGridView(views: [
            [keyRowLabel,  keyRow],
            [holdRowLabel, holdStack],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 8

        cv.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -20),
            triggerKeyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
    }

    private func updateUI() {
        let key = keyMonitor.triggerKey
        triggerKeyLabel.stringValue = key.displayName
        let ms = key.holdThreshold * 1000
        holdSlider.doubleValue = ms
        holdValueLabel.stringValue = ms == 0 ? "Instant" : "\(Int(ms)) ms"
    }

    @objc private func startRecording() {
        recordKeyButton.isEnabled = false
        recordKeyButton.title = "Press any key… (Esc to cancel)"

        keyMonitor.captureNextKey { [weak self] captured in
            guard let self else { return }
            if let key = captured {
                var newKey = key
                newKey.holdThreshold = self.keyMonitor.triggerKey.holdThreshold
                self.keyMonitor.triggerKey = newKey
                newKey.save()
            }
            self.updateUI()
            self.recordKeyButton.title = "Record Key…"
            self.recordKeyButton.isEnabled = true
        }
    }

    @objc private func sliderMoved() {
        let ms = holdSlider.doubleValue
        holdValueLabel.stringValue = ms == 0 ? "Instant" : "\(Int(ms)) ms"
        keyMonitor.triggerKey.holdThreshold = ms / 1000
        keyMonitor.triggerKey.save()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        keyMonitor.cancelCapture()
        recordKeyButton.title = "Record Key…"
        recordKeyButton.isEnabled = true
    }
}
