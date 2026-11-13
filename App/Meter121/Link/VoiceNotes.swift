// Voice notes while recording (GitHub issue 1 of the iPhone app): the microphone is listened to and the speech is
// turned into text on the iPhone only (SFSpeechRecognizer with requiresOnDeviceRecognition; no audio is kept and
// nothing leaves the phone).  The audio goes to one recognition request at a time ("piece"); a piece ends after a
// pause in the speech, or after about a minute, and the next one starts at once, so long recordings have no gaps.
// The final result of a piece is split into phrases at gaps between words; each phrase gets the wall-clock time it
// began (the time of the piece's first audio plus the word's offset in it).

import AVFoundation
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
    private(set) var running = false

    static let pause: TimeInterval = 1.2     // silence after speech that ends a piece
    static let pieceMax: TimeInterval = 50   // a piece is ended at the next pause after this many seconds
    static let pieceHard: TimeInterval = 75  // ... and at the latest after this many
    static let phraseGap: TimeInterval = 0.8 // a gap between two words this long starts a new phrase
    static let stopWait: TimeInterval = 3    // seconds stop() waits for the last piece's text

    private final class Piece {
        var start: Date?                     // wall clock of the piece's first audio (set by the audio thread)
        var text = ""                        // the latest partial text
        var segments: [(String, TimeInterval, TimeInterval)] = []   // words of the latest result: text, offset, length
        var done = false
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()              // request and piece: the audio thread appends, the main queue swaps
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var piece: Piece?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var pieceStarted = Date()
    private var lastChange = Date()
    private var timer: Timer?

    /// Asks for speech recognition and the microphone (each once; later answers come from Settings).
    static func authorize() async throws {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { throw Failure.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.micDenied }
    }

    func start() throws {
        guard !running else { return }
        guard let r = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer() else { throw Failure.noRecognizer }
        guard r.supportsOnDeviceRecognition else { throw Failure.notOnDevice }
        recognizer = r
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw Failure.audio(error.localizedDescription)
        }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.audio(error.localizedDescription)
        }
        running = true
        newPiece()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Stops listening; `done` runs on the main queue once the last piece's text has arrived (or after stopWait).
    func stop(_ done: @escaping () -> Void) {
        guard running else { done(); return }
        running = false
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let last = endPiece()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let deadline = Date().addingTimeInterval(Self.stopWait)
        func wait() {
            if last?.done ?? true || Date() >= deadline {
                if let last, !last.done { finish(last) }       // no final result in time: the latest words
                done()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: wait)
            }
        }
        wait()
    }

    // MARK: pieces

    private func append(_ buffer: AVAudioPCMBuffer) {             // the audio thread
        lock.lock()
        defer { lock.unlock() }
        guard let request, let piece else { return }
        if piece.start == nil {
            let seconds = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            piece.start = Date().addingTimeInterval(-seconds)      // the buffer arrives when its audio has ended
        }
        request.append(buffer)
    }

    private func newPiece() {
        guard let recognizer else { return }
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
                self?.handle(p, text: text, words: words, final: final, failed: error != nil)
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
        guard running else { return }
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

    private func handle(_ p: Piece, text: String?, words: [(String, TimeInterval, TimeInterval)]?, final: Bool, failed: Bool) {
        if let text, !p.done {
            if text != p.text {
                p.text = text
                lastChange = Date()
                if !text.isEmpty { onHeard?(text) }
            }
            if let words { p.segments = words }
        }
        if final && !p.done {
            finish(p)
        } else if failed && !p.done {
            finish(p)                                              // e.g. no speech in the piece: nothing to write
        }
        tasks.removeAll { $0.state == .completed || $0.state == .canceling }
    }

    /// The piece's words as phrases (split at gaps of phraseGap), each with the time it began.
    private func finish(_ p: Piece) {
        p.done = true
        guard !p.segments.isEmpty, let base = p.start else { return }
        var groups: [[(String, TimeInterval, TimeInterval)]] = []
        for w in p.segments {
            if let last = groups.last?.last, w.1 - (last.1 + last.2) <= Self.phraseGap {
                groups[groups.count - 1].append(w)
            } else {
                groups.append([w])
            }
        }
        for g in groups {                                          // one phrase: the punctuated text as recognised
            let text = groups.count == 1 ? p.text : g.map { $0.0 }.joined(separator: " ")
            onPhrase?(NotePhrase(start: base.addingTimeInterval(g[0].1), text: text))
        }
    }
}
