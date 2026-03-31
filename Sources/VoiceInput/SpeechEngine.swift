import AVFoundation
import Speech

final class SpeechEngine {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onLocaleUnavailable: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()

    // Primary recognizer (user-selected locale)
    private var primaryRecognizer: SFSpeechRecognizer?
    private var primaryRequest: SFSpeechAudioBufferRecognitionRequest?
    private var primaryTask: SFSpeechRecognitionTask?

    // Secondary recognizer (en-US, for mixed Chinese/English)
    private var secondaryRecognizer: SFSpeechRecognizer?
    private var secondaryRequest: SFSpeechAudioBufferRecognitionRequest?
    private var secondaryTask: SFSpeechRecognitionTask?
    private var secondarySegments: [SFTranscriptionSegment] = []
    private var secondaryFinalText: String = ""
    private let segmentsLock = NSLock()

    // Session tracking to ignore stale callbacks
    private var sessionID: UInt64 = 0
    private var primaryHasResult = false

    private var dualMode: Bool { needsDualRecognizer(locale) }

    var locale: Locale {
        didSet {
            primaryRecognizer = SFSpeechRecognizer(locale: locale)
            if primaryRecognizer == nil {
                onLocaleUnavailable?("Speech recognition is not supported for \(locale.identifier). Please check that the language is downloaded in System Settings → General → Keyboard → Dictation.")
            }
            setupSecondaryIfNeeded()
        }
    }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        self.primaryRecognizer = SFSpeechRecognizer(locale: locale)
        setupSecondaryIfNeeded()
    }

    private func setupSecondaryIfNeeded() {
        if needsDualRecognizer(locale) {
            secondaryRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        } else {
            secondaryRecognizer = nil
        }
    }

    private func needsDualRecognizer(_ locale: Locale) -> Bool {
        let lang = locale.identifier.lowercased()
        return lang.hasPrefix("zh")
    }

    // MARK: - Permissions

    static func requestPermissions(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            if granted {
                                completion(true, nil)
                            } else {
                                completion(false, "Microphone access denied.\nGrant in System Settings → Privacy & Security → Microphone.")
                            }
                        }
                    }
                case .denied, .restricted:
                    completion(false, "Speech recognition denied.\nGrant in System Settings → Privacy & Security → Speech Recognition.")
                case .notDetermined:
                    completion(false, "Speech recognition permission not determined.")
                @unknown default:
                    completion(false, "Unknown speech recognition authorization status.")
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        // Full cleanup of any previous session
        cleanup()

        sessionID &+= 1
        let currentSession = sessionID
        primaryHasResult = false

        guard let recognizer = primaryRecognizer, recognizer.isAvailable else {
            onError?("Speech recognizer not available for \(locale.identifier)")
            return
        }

        // Primary request
        let pRequest = SFSpeechAudioBufferRecognitionRequest()
        pRequest.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            pRequest.addsPunctuation = true
        }
        primaryRequest = pRequest

        // Secondary request (en-US) if dual mode — no partial results needed
        var sRequest: SFSpeechAudioBufferRecognitionRequest?
        if dualMode, let secRecognizer = secondaryRecognizer, secRecognizer.isAvailable {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = false
            if #available(macOS 13, *) {
                req.addsPunctuation = true
            }
            secondaryRequest = req
            sRequest = req

            secondaryTask = secRecognizer.recognitionTask(with: req) { [weak self] result, _ in
                guard let self, self.sessionID == currentSession else { return }
                if let result {
                    self.segmentsLock.lock()
                    self.secondarySegments = Array(result.bestTranscription.segments)
                    self.secondaryFinalText = result.bestTranscription.formattedString
                    self.segmentsLock.unlock()
                }
            }
        }

        primaryTask = recognizer.recognitionTask(with: pRequest) { [weak self] result, error in
            guard let self, self.sessionID == currentSession else { return }
            if let result {
                self.primaryHasResult = true
                if result.isFinal {
                    let merged = self.mergeIfNeeded(result.bestTranscription)
                    self.onFinalResult?(merged)
                } else {
                    let text = result.bestTranscription.formattedString
                    self.onPartialResult?(text)
                }
            }
            // Only report errors when we never got any result at all
            if let error, result == nil, !self.primaryHasResult {
                let code = (error as NSError).code
                if code != 216 && code != 1110 && code != 301 {
                    self.onError?(error.localizedDescription)
                }
            }
        }

        // Single audio tap feeds both requests
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            pRequest.append(buffer)
            sRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrtf(sum / Float(max(frameLength, 1)))
            let dB = 20 * log10(max(rms, 1e-6))
            let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
            DispatchQueue.main.async {
                self?.onAudioLevel?(normalized)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onError?("Audio engine failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        primaryRequest?.endAudio()
        secondaryRequest?.endAudio()
    }

    /// Called by AppDelegate after finishTranscription to free all resources.
    func finalize() {
        primaryTask?.cancel()
        secondaryTask?.cancel()
        primaryRequest = nil
        primaryTask = nil
        secondaryRequest = nil
        secondaryTask = nil
        segmentsLock.lock()
        secondarySegments = []
        secondaryFinalText = ""
        segmentsLock.unlock()
        primaryHasResult = false
    }

    func cancel() {
        cleanup()
    }

    /// Returns the secondary (en-US) full text, if available.
    /// Used as fallback when primary produced no result.
    func secondaryResult() -> String? {
        segmentsLock.lock()
        let text = secondaryFinalText
        segmentsLock.unlock()
        return text.isEmpty ? nil : text
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        primaryTask?.cancel()
        secondaryTask?.cancel()
        primaryRequest = nil
        primaryTask = nil
        secondaryRequest = nil
        secondaryTask = nil
        segmentsLock.lock()
        secondarySegments = []
        secondaryFinalText = ""
        segmentsLock.unlock()
        primaryHasResult = false
    }

    // MARK: - Segment Merging

    private func mergeIfNeeded(_ transcription: SFTranscription) -> String {
        segmentsLock.lock()
        let secSegs = secondarySegments
        segmentsLock.unlock()

        guard dualMode, !secSegs.isEmpty else {
            return transcription.formattedString
        }

        let primarySegs = transcription.segments
        guard !primarySegs.isEmpty else { return transcription.formattedString }

        var parts: [String] = []
        var prevWasEnglish = false

        for seg in primarySegs {
            let sub = seg.substring
            if containsLatin(sub) {
                if !prevWasEnglish && !parts.isEmpty && !parts.last!.hasSuffix(" ") {
                    parts.append(" ")
                }
                parts.append(sub)
                prevWasEnglish = true
            } else if isAllCJK(sub) {
                if let replacement = findEnglishReplacement(for: seg, in: secSegs) {
                    if !parts.isEmpty && !parts.last!.hasSuffix(" ") {
                        parts.append(" ")
                    }
                    parts.append(replacement)
                    prevWasEnglish = true
                } else {
                    if prevWasEnglish && !parts.isEmpty {
                        parts.append(" ")
                    }
                    parts.append(sub)
                    prevWasEnglish = false
                }
            } else {
                parts.append(sub)
                prevWasEnglish = false
            }
        }

        return parts.joined()
    }

    private func findEnglishReplacement(for segment: SFTranscriptionSegment, in secSegs: [SFTranscriptionSegment]) -> String? {
        let segStart = segment.timestamp
        let segEnd = segStart + segment.duration

        var overlapping: [SFTranscriptionSegment] = []
        for sec in secSegs {
            let secStart = sec.timestamp
            let secEnd = secStart + sec.duration
            if secStart < segEnd && secEnd > segStart {
                overlapping.append(sec)
            }
        }

        guard !overlapping.isEmpty else { return nil }

        let combined = overlapping.map { $0.substring }.joined(separator: " ")
        let trimmed = combined.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty, isLatinText(trimmed) else { return nil }

        return trimmed
    }

    // MARK: - Character Classification

    private func containsLatin(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && scalar.value < 0x3000
        }
    }

    private func isAllCJK(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        return stripped.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) ||
            (scalar.value >= 0x3400 && scalar.value <= 0x4DBF) ||
            (scalar.value >= 0x2E80 && scalar.value <= 0x2EFF) ||
            (scalar.value >= 0xF900 && scalar.value <= 0xFAFF) ||
            (scalar.value >= 0x20000 && scalar.value <= 0x2A6DF) ||
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
            CharacterSet.punctuationCharacters.contains(scalar)
        }
    }

    private func isLatinText(_ s: String) -> Bool {
        let stripped = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        return stripped.unicodeScalars.allSatisfy { scalar in
            scalar.value < 0x3000 ||
            CharacterSet.whitespacesAndNewlines.contains(scalar) ||
            CharacterSet.punctuationCharacters.contains(scalar)
        }
    }
}
