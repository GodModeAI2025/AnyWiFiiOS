import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

/// Spracheingabe für den Profil-Chat (01 §4.3): SpeechAnalyzer + SpeechTranscriber, auf dem Gerät.
/// Nur in der Haupt-App, nie in der Network Extension.
@available(iOS 26.0, *)
@MainActor
@Observable
final class VoiceInput {
    private(set) var isRecording = false
    private(set) var transcript = ""
    var errorMessage: String?

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        transcript = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Kein Zugriff auf das Mikrofon."
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE")) else {
            errorMessage = "Deutsch wird für die Spracherkennung nicht unterstützt."
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                errorMessage = "Kein passendes Audioformat."
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            try Self.installTap(on: engine, targetFormat: format, continuation: continuation)
            engine.prepare()
            try engine.start()

            self.engine = engine
            self.continuation = continuation
            self.analyzer = analyzer
            isRecording = true

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results where result.isFinal {
                        let text = String(result.text.characters)
                        self?.append(text)
                    }
                } catch {
                    self?.errorMessage = "Spracherkennung unterbrochen."
                }
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            errorMessage = "Spracheingabe nicht möglich: \(error.localizedDescription)"
            await stop()
        }
    }

    func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript += transcript.isEmpty ? trimmed : " " + trimmed
    }

    /// Bewusst `nonisolated`: Der Tap-Block läuft auf dem Audio-Thread, nicht auf dem MainActor.
    nonisolated private static func installTap(on engine: AVAudioEngine, targetFormat: AVAudioFormat,
                                               continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = inputFormat == targetFormat ? nil : AVAudioConverter(from: inputFormat, to: targetFormat)
        let box = ConverterBox(converter: converter, format: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let converted = box.convert(buffer) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }
}

/// Kapselt den AVAudioConverter für den Audio-Thread.
private final class ConverterBox: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat

    init(converter: AVAudioConverter?, format: AVAudioFormat) {
        self.converter = converter
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let state = OneShot()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if state.used {
                status.pointee = .noDataNow
                return nil
            }
            state.used = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}

private final class OneShot: @unchecked Sendable {
    var used = false
}

/// Mikrofon-Button für den Chat. Fügt die erkannte Anweisung ins Eingabefeld ein.
@available(iOS 26.0, *)
struct VoiceButton: View {
    let onText: (String) -> Void
    @State private var voice = VoiceInput()

    var body: some View {
        Button {
            Task {
                if voice.isRecording {
                    await voice.stop()
                    if !voice.transcript.isEmpty { onText(voice.transcript) }
                } else {
                    await voice.start()
                }
            }
        } label: {
            Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.circle")
                .font(.title2)
                .foregroundStyle(voice.isRecording ? .red : .accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(voice.isRecording ? "Aufnahme beenden" : "Per Sprache beschreiben")
        .help(voice.errorMessage ?? "")
    }
}
