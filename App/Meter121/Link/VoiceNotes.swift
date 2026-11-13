// Voice notes while recording (GitHub issue 1 of the iPhone app): the microphone is listened to and the speech is
// turned into text on the iPhone only; no audio is kept and nothing leaves the phone.  Each phrase gets the wall-clock
// time it began: the time of the first audio plus the phrase's offset in the audio.
//
// iOS 26 and newer: SpeechAnalyzer with a SpeechTranscriber (Speech framework, on-device by design); it segments long
// audio itself and stamps the text with its audio time range.  Its language model is an Apple asset, downloaded once
// if the phone does not have it yet.
// iOS 17 to 25: SFSpeechRecognizer with requiresOnDeviceRecognition; the audio goes to one request at a time
// ("piece"), ended after a pause in the speech or after about a minute, the next one starting at once.

import AVFoundation
import CoreMedia
import Foundation
import Meter121Kit
import Speech

final class VoiceNotes {
    enum Failure: LocalizedError {
        case speechDenied, micDenied, noRecognizer, notOnDevice, audio(String)

        var errorDescription: String? {
            switch self {
            case .speechDenied: return "Voice notes need speech recognition: allow it in Settings › 121GW."
            case .micDenied: return "Voice notes need the microphone: allow it in Settings › 121GW."
            case .noRecognizer: return "Speech recognition is not available for this iPhone's language."
            case .notOnDevice: return "This iPhone cannot recognise speech on the phone itself in its language, and the "
                + "app does not send your voice anywhere: voice notes are not available."
            case .audio(let s): return "The microphone could not be started: \(s)"
            }
        }
    }

    var onPhrase: ((NotePhrase) -> Void)?    // a finished phrase (main queue)
    var onHeard: ((String) -> Void)?         // the words being heard now (main queue)
    var onStatus: ((String) -> Void)?        // e.g. the one-time download of the speech model (main queue)
    private(set) var running = false

    static let phraseGap: TimeInterval = 0.8 // a gap between two words this long starts a new phrase
    static let stopWait: TimeInterval = 5    // seconds stop() waits for the last text

    private let engine = AVAudioEngine()
    private var recognizer: Recognizer?

    /// Asks for speech recognition and the microphone (each once; later answers come from Settings).
    static func authorize() async throws {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { throw Failure.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.micDenied }
    }

    @MainActor
    func start() async throws {
        guard !running else { return }
        let r: Recognizer
        if #available(iOS 26, *) {
            r = try await AnalyzerRecognizer.make(status: { [weak self] s in self?.onStatus?(s) })
        } else {
            r = try LegacyRecognizer(locale: .current)
        }
        r.onPhrase = { [weak self] p in self?.onPhrase?(p) }
        r.onHeard = { [weak self] t in self?.onHeard?(t) }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw Failure.audio(error.localizedDescription)
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            r.append(buffer)                                           // the audio thread
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.audio(error.localizedDescription)
        }
        recognizer = r
        running = true
        r.begin()
    }

    /// Stops listening; `done` runs on the main queue once the last text has arrived (or after stopWait).
    func stop(_ done: @escaping () -> Void) {
        guard running, let r = recognizer else { done(); return }
        running = false
        recognizer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        var called = false
        let once = { if !called { called = true; done() } }
        r.finish { DispatchQueue.main.async(execute: once) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopWait, execute: once)
    }

    /// Words with their audio offset and length -> phrases, split at gaps of phraseGap.
    static func phrases(_ words: [(String, TimeInterval, TimeInterval)], base: Date, whole: String?) -> [NotePhrase] {
        var groups: [[(String, TimeInterval, TimeInterval)]] = []
        for w in words {
            if let last = groups.last?.last, w.1 - (last.1 + last.2) <= phraseGap {
                groups[groups.count - 1].append(w)
            } else {
                groups.append([w])
            }
        }
        return groups.map { g in                                   // one phrase: the punctuated text as recognised
            let text = groups.count == 1 && whole != nil ? whole! : g.map { $0.0 }.joined(separator: " ")
            return NotePhrase(start: base.addingTimeInterval(g[0].1), text: text)
        }
    }
}

/// One way of turning audio into phrases.
private class Recognizer {
    var onPhrase: ((NotePhrase) -> Void)?
    var onHeard: ((String) -> Void)?
    func begin() {}
    func append(_ buffer: AVAudioPCMBuffer) {}                    // the audio thread
    func finish(_ done: @escaping () -> Void) { done() }
}

// MARK: - iOS 26 and newer

@available(iOS 26, *)
private final class AnalyzerRecognizer: Recognizer {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat?
    private let input: AsyncStream<AnalyzerInput>
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var base: Date?                                       // wall clock of the first audio
    private var results: Task<Void, Never>?

    static func make(status: @escaping (String) -> Void) async throws -> AnalyzerRecognizer {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceNotes.Failure.notOnDevice
        }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                  attributeOptions: [.audioTimeRange])
        switch await AssetInventory.status(forModules: [t]) {
        case .unsupported:
            throw VoiceNotes.Failure.notOnDevice
        case .installed:
            break
        default:                                                  // the on-device model: an Apple asset, once
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                await MainActor.run { status("Downloading the speech model for \(locale.identifier) (once)…") }
                try await request.downloadAndInstall()
                await MainActor.run { status("") }
            }
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let analyzer = SpeechAnalyzer(modules: [t])
        try await analyzer.prepareToAnalyze(in: format)
        return AnalyzerRecognizer(transcriber: t, analyzer: analyzer, format: format)
    }

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat?) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
    }

    override func begin() {
        let t = transcriber, a = analyzer, stream = input
        results = Task { [weak self] in
            do {
                try await a.start(inputSequence: stream)
                for try await r in t.results {
                    self?.result(r)
                }
            } catch {
                // the analysis ended (finished, or the audio stopped): the phrases so far are written
            }
        }
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if base == nil {
            let seconds = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            base = Date().addingTimeInterval(-seconds)            // the buffer arrives when its audio has ended
        }
        guard let out = convert(buffer) else { return }
        feed.yield(AnalyzerInput(buffer: out))
    }

    override func finish(_ done: @escaping () -> Void) {
        feed.finish()
        let a = analyzer, r = results
        Task {
            try? await a.finalizeAndFinishThroughEndOfInput()
            await r?.value
            done()
        }
    }

    private func result(_ r: SpeechTranscriber.Result) {
        let whole = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return }
        if !r.isFinal {
            DispatchQueue.main.async { [weak self] in self?.onHeard?(whole) }
            return
        }
        lock.lock()
        let b = base ?? Date()
        lock.unlock()
        var words: [(String, TimeInterval, TimeInterval)] = []
        for run in r.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !w.isEmpty { words.append((w, range.start.seconds, range.duration.seconds)) }
        }
        let phrases = words.isEmpty ? [NotePhrase(start: b.addingTimeInterval(r.range.start.seconds), text: whole)]
            : VoiceNotes.phrases(words, base: b, whole: whole)
        DispatchQueue.main.async { [weak self] in
            for p in phrases { self?.onPhrase?(p) }
        }
    }

    /// The microphone's buffer in the format the analyzer wants (lock held).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format, format != buffer.format else { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let frames = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: - iOS 17 to 25

private final class LegacyRecognizer: Recognizer {
    static let pause: TimeInterval = 1.2     // silence after speech that ends a piece
    static let pieceMax: TimeInterval = 50   // a piece is ended at the next pause after this many seconds
    static let pieceHard: TimeInterval = 75  // ... and at the latest after this many

    private final class Piece {
        var start: Date?                     // wall clock of the piece's first audio (set by the audio thread)
        var text = ""                        // the latest partial text
        var words: [(String, TimeInterval, TimeInterval)] = []   // words of the latest result: text, offset, length
        var done = false
    }

    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()              // request and piece: the audio thread appends, the main queue swaps
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var piece: Piece?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var pieceStarted = Date()
    private var lastChange = Date()
    private var timer: Timer?
    private var stopping: (piece: Piece, done: () -> Void)?

    init(locale: Locale) throws {
        guard let r = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw VoiceNotes.Failure.noRecognizer
        }
        guard r.supportsOnDeviceRecognition else { throw VoiceNotes.Failure.notOnDevice }
        recognizer = r
    }

    override func begin() {
        newPiece()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let request, let piece else { return }
        if piece.start == nil {
            let seconds = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            piece.start = Date().addingTimeInterval(-seconds)
        }
        request.append(buffer)
    }

    override func finish(_ done: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            timer = nil
            guard let last = endPiece(), !last.done else { done(); return }
            stopping = (last, done)                               // done follows the last piece's final text
        }
    }

    private func newPiece() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true                     // never Apple's servers
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        let p = Piece()
        lock.lock()
        request = req
        piece = p
        lock.unlock()
        pieceStarted = Date()
        lastChange = pieceStarted
        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let words = result?.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) }
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            DispatchQueue.main.async {
                self?.handle(p, text: text, words: words, final: final || error != nil)
            }
        }
        tasks.append(task)
    }

    /// Ends the audio of the current piece (its final result follows) and returns it.
    @discardableResult
    private func endPiece() -> Piece? {
        lock.lock()
        let req = request, p = piece
        request = nil
        piece = nil
        lock.unlock()
        req?.endAudio()
        return p
    }

    private func tick() {
        let now = Date()
        lock.lock()
        let heard = !(piece?.text.isEmpty ?? true)
        lock.unlock()
        let silent = now.timeIntervalSince(lastChange)
        let age = now.timeIntervalSince(pieceStarted)
        if (heard && silent > Self.pause) || (age > Self.pieceMax && silent > Self.pause) || age > Self.pieceHard {
            endPiece()
            newPiece()
        }
    }

    private func handle(_ p: Piece, text: String?, words: [(String, TimeInterval, TimeInterval)]?, final: Bool) {
        if let text, !p.done {
            if text != p.text {
                p.text = text
                lastChange = Date()
                if !text.isEmpty { onHeard?(text) }
            }
            if let words { p.words = words }
        }
        if final && !p.done {                                      // final text, or an error (e.g. no speech)
            p.done = true
            if !p.words.isEmpty, let base = p.start {
                for ph in VoiceNotes.phrases(p.words, base: base, whole: p.text) { onPhrase?(ph) }
            }
            if let s = stopping, s.piece === p {
                stopping = nil
                s.done()
            }
        }
        tasks.removeAll { $0.state == .completed || $0.state == .canceling }
    }
}
