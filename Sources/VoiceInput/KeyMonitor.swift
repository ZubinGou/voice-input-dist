import Cocoa

// MARK: - TriggerKey

struct TriggerKey {
    enum Mode {
        case fn                              // macOS built-in Fn key (maskSecondaryFn)
        case regular(UInt16)                 // Normal key: detected via keyDown/keyUp
        case modifier(UInt16, CGEventFlags)  // Modifier key: detected via flagsChanged
    }

    var mode: Mode
    /// Seconds to hold before recording starts. 0 = instant trigger.
    var holdThreshold: TimeInterval

    static let `default` = TriggerKey(mode: .fn, holdThreshold: 0)

    // MARK: Persistence

    static func load() -> TriggerKey {
        let ud = UserDefaults.standard
        guard ud.object(forKey: "triggerKeyCode") != nil else { return .default }
        let code = ud.integer(forKey: "triggerKeyCode")
        let threshold = ud.double(forKey: "triggerHoldThreshold")
        if code < 0 {
            return TriggerKey(mode: .fn, holdThreshold: threshold)
        }
        let rawFlag = ud.object(forKey: "triggerModifierFlag") as? UInt64 ?? 0
        let keyCode = UInt16(code)
        if rawFlag != 0 {
            return TriggerKey(mode: .modifier(keyCode, CGEventFlags(rawValue: rawFlag)),
                              holdThreshold: threshold)
        }
        return TriggerKey(mode: .regular(keyCode), holdThreshold: threshold)
    }

    func save() {
        let ud = UserDefaults.standard
        ud.set(holdThreshold, forKey: "triggerHoldThreshold")
        switch mode {
        case .fn:
            ud.set(-1, forKey: "triggerKeyCode")
            ud.set(UInt64(0), forKey: "triggerModifierFlag")
        case .regular(let code):
            ud.set(Int(code), forKey: "triggerKeyCode")
            ud.set(UInt64(0), forKey: "triggerModifierFlag")
        case .modifier(let code, let flag):
            ud.set(Int(code), forKey: "triggerKeyCode")
            ud.set(flag.rawValue, forKey: "triggerModifierFlag")
        }
    }

    // MARK: Display

    var displayName: String {
        let keyName: String
        switch mode {
        case .fn:                       keyName = "Fn (System)"
        case .regular(let c):           keyName = TriggerKey.keyCodeName(c)
        case .modifier(let c, _):       keyName = TriggerKey.keyCodeName(c)
        }
        if holdThreshold > 0 {
            return "\(keyName)  (hold \(Int(holdThreshold * 1000)) ms)"
        }
        return keyName
    }

    static func keyCodeName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            36: "Return",      48: "Tab",         49: "Space",       51: "Delete",
            53: "Escape",      54: "Right ⌘",     55: "Left ⌘",      56: "Left ⇧",
            57: "Caps Lock",   58: "Left ⌥",      59: "Left ⌃",
            60: "Right ⇧",     61: "Right ⌥",     62: "Right ⌃",     63: "Fn",
            96: "F5",          97: "F6",           98: "F7",          99: "F3",
            100: "F8",         101: "F9",          103: "F11",        105: "F13",
            107: "F14",        109: "F10",         111: "F12",        113: "F15",
            115: "Home",       116: "Page Up",     117: "Fwd Delete",
            118: "F4",         119: "End",         120: "F2",         121: "Page Down",
            122: "F1",         123: "←",           124: "→",          125: "↓",  126: "↑",
        ]
        return names[code] ?? "Key(\(code))"
    }

    /// Map a modifier keyCode to the CGEventFlag it sets when pressed.
    static let modifierFlagForKeyCode: [UInt16: CGEventFlags] = [
        54: .maskCommand,     55: .maskCommand,
        56: .maskShift,       60: .maskShift,
        58: .maskAlternate,   61: .maskAlternate,
        59: .maskControl,     62: .maskControl,
        63: .maskSecondaryFn,
    ]
}

// MARK: - KeyMonitor

final class KeyMonitor {
    var triggerKey: TriggerKey = TriggerKey.load()
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // State machine for hold detection
    private enum HoldState { case idle, pending, recording, combo }
    private var holdState: HoldState = .idle
    private var holdTimer: Timer?

    // Shared "key is down" flag (used only for instant-trigger modes)
    private var triggerPressed = false

    // Capture mode
    private var captureCompletion: ((TriggerKey?) -> Void)?

    // MARK: - Lifecycle

    func start() -> Bool {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)      |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let m = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return m.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = eventTap     { CGEvent.tapEnable(tap: t, enable: false) }
        runLoopSource = nil
        eventTap = nil
        cancelHoldTimer()
        holdState = .idle
    }

    /// Enter capture mode — next meaningful key press is reported via completion.
    /// completion(nil) means the user pressed Escape (cancelled).
    func captureNextKey(completion: @escaping (TriggerKey?) -> Void) {
        captureCompletion = completion
    }

    func cancelCapture() {
        if let c = captureCompletion {
            captureCompletion = nil
            DispatchQueue.main.async { c(nil) }
        }
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if let capture = captureCompletion {
            return handleCapture(type: type, event: event, completion: capture)
        }

        switch triggerKey.mode {
        case .fn:
            return handleFn(type: type, event: event)
        case .regular(let code):
            return handleRegular(type: type, event: event, targetCode: code)
        case .modifier(let code, let flag):
            return handleModifier(type: type, event: event, targetCode: code, targetFlag: flag)
        }
    }

    // MARK: Capture

    private func handleCapture(
        type: CGEventType,
        event: CGEvent,
        completion: @escaping (TriggerKey?) -> Void
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            captureCompletion = nil
            let result: TriggerKey? = code == 53 ? nil : TriggerKey(mode: .regular(code),
                                                                     holdThreshold: triggerKey.holdThreshold)
            DispatchQueue.main.async { completion(result) }
            return nil

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Apple Fn key
            if event.flags.contains(.maskSecondaryFn) {
                captureCompletion = nil
                DispatchQueue.main.async { completion(TriggerKey(mode: .fn,
                                                                 holdThreshold: self.triggerKey.holdThreshold)) }
                return nil
            }
            // Any other modifier key (Right Option, Right Command, etc.)
            if let flag = TriggerKey.modifierFlagForKeyCode[code], event.flags.contains(flag) {
                captureCompletion = nil
                DispatchQueue.main.async { completion(TriggerKey(mode: .modifier(code, flag),
                                                                 holdThreshold: self.triggerKey.holdThreshold)) }
                return nil
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: Apple Fn mode (always suppresses to prevent emoji picker)

    private func handleFn(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passRetained(event) }
        let fnDown = event.flags.contains(.maskSecondaryFn)

        if fnDown && !triggerPressed {
            triggerPressed = true
            if triggerKey.holdThreshold > 0 {
                holdState = .pending
                startHoldTimer()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            }
            return nil
        } else if !fnDown && triggerPressed {
            triggerPressed = false
            switch holdState {
            case .pending:
                cancelHoldTimer()
                holdState = .idle
                // Short press: Fn was suppressed so nothing to replay; just swallow.
            case .recording:
                cancelHoldTimer()
                holdState = .idle
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            default:
                if triggerKey.holdThreshold == 0 {
                    DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                }
                holdState = .idle
            }
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: Regular key mode (suppressive)

    private func handleRegular(type: CGEventType, event: CGEvent, targetCode: UInt16) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passRetained(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == targetCode else { return Unmanaged.passRetained(event) }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .keyDown && !isRepeat && !triggerPressed {
            triggerPressed = true
            if triggerKey.holdThreshold > 0 {
                holdState = .pending
                startHoldTimer()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onFnDown?() }
            }
        } else if type == .keyUp && triggerPressed {
            triggerPressed = false
            switch holdState {
            case .pending:
                cancelHoldTimer()
                holdState = .idle
                // Short press: event was suppressed; just swallow.
            case .recording:
                cancelHoldTimer()
                holdState = .idle
                DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
            default:
                if triggerKey.holdThreshold == 0 {
                    DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                }
                holdState = .idle
            }
        }
        return nil // always suppress the trigger key
    }

    // MARK: Modifier key mode (NON-suppressive — preserves all combos)
    //
    // Events are always passed through so that Opt+key, Cmd+key, etc.
    // continue to work exactly as before. We only OBSERVE the events and
    // use a timer to decide whether it's a "hold alone" gesture.

    private func handleModifier(
        type: CGEventType,
        event: CGEvent,
        targetCode: UInt16,
        targetFlag: CGEventFlags
    ) -> Unmanaged<CGEvent>? {

        switch type {
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if code == targetCode {
                let isDown = event.flags.contains(targetFlag)
                if isDown && holdState == .idle {
                    holdState = .pending
                    startHoldTimer()
                } else if !isDown {
                    switch holdState {
                    case .pending:
                        // Released before threshold — short tap, no recording.
                        cancelHoldTimer()
                        holdState = .idle
                    case .recording:
                        cancelHoldTimer()
                        holdState = .idle
                        DispatchQueue.main.async { [weak self] in self?.onFnUp?() }
                    default:
                        holdState = .idle
                    }
                }
            } else if holdState == .pending {
                // A different modifier changed → it's a combination, cancel.
                cancelHoldTimer()
                holdState = .combo
            }

        case .keyDown where holdState == .pending:
            // Another key pressed while waiting → combination, cancel recording intent.
            cancelHoldTimer()
            holdState = .combo

        case .keyUp where holdState == .combo:
            // Combo key released; if the trigger modifier is also up, return to idle.
            // (target modifier up is handled in the flagsChanged branch above)
            break

        default:
            break
        }

        return Unmanaged.passRetained(event) // always pass through
    }

    // MARK: Hold timer

    private func startHoldTimer() {
        holdTimer?.invalidate()
        let threshold = triggerKey.holdThreshold
        holdTimer = Timer.scheduledTimer(withTimeInterval: threshold, repeats: false) { [weak self] _ in
            guard let self, self.holdState == .pending else { return }
            self.holdState = .recording
            DispatchQueue.main.async { self.onFnDown?() }
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
