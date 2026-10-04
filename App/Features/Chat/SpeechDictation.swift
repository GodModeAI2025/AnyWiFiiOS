import Foundation
import AVFoundation
import Speech

/// Spracheingabe mit SpeechAnalyzer/SpeechTranscriber (01 §4.3). Läuft nur in der Haupt-App.
@Observable @MainActor
final class SpeechDictation {
    enum State: Equatable { case idle, preparing, recording, denied, unavailable }

    private(set) var state: State = .idle
    private(set) var transcript = ""

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var committed = ""

    var isRecording: Bool { state == .recording }

    func toggle() async {
        if isRecording { await stop() } else { await start() }
    }

    func start() async {
        guard state == .idle || state == .denied || state == .unavailable else { return }
        state = .preparing
        guard await AVAudioApplication.requestRecordPermission() else { state = .denied; return }
        let locale = Locale(identifier: Locale.current.language.languageCode?.identifier == "en" ? "en-US" : "de-DE")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { state = .unavailable; return }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { state = .unavailable; return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            inputContinuation = continuation
            committed = ""
            transcript = ""

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run {
                            guard let self else { return }
                            if result.isFinal { self.committed += text + " "; self.transcript = self.committed }
                            else { self.transcript = self.committed + text }
                        }
                    }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
            try startEngine(targetFormat: format, continuation: continuation)
            state = .recording
        } catch {
            await stop()
            state = .unavailable
        }
    }

    private func startEngine(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = inputFormat == targetFormat ? nil : AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converter else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state != .denied && state != .unavailable { state = .idle }
    }

    /// Übernimmt den erkannten Text und leert ihn.
    func takeTranscript() -> String {
        let t = transcript.trimmingCharacters(in: .whitespaces)
        transcript = ""
        committed = ""
        return t
    }
}
