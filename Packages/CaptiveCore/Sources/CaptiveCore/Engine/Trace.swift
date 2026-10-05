import Foundation

/// Erfasste Seite eines Laufs: normalisierter Zustand plus Roh-HTML (für das Debug-Paket,
/// dort redigiert).
public struct CapturedPage: Sendable {
    public var normalized: NormalizedPage
    public var html: String
}

/// Ein ausgeführter Schritt (01 §12.3). `control` ist das aufgelöste Element, ohne Werte.
public struct TraceStep: Sendable {
    public var index: Int
    public var pageIndex: Int
    public var stageId: String?
    public var action: Action
    public var control: NormalizedControl?
    public var matchScore: Int?
    public var valueRef: String?
    public var urlBefore: String
    public var urlAfter: String?
    public var status: Int?
    public var durationMs: Int
    public var result: String
}

/// Serialisierbare, redigierte Form eines Schritts für `trace.jsonl`.
public struct TraceRecord: Codable, Equatable, Sendable {
    public var step: Int
    public var page: Int
    public var stage: String?
    public var action: String
    public var element: String?
    public var concept: String?
    public var confidence: Int?
    public var value: String?
    public var urlBefore: String
    public var urlAfter: String?
    public var status: Int?
    public var durationMs: Int
    public var result: String

    public init(_ s: TraceStep) {
        step = s.index
        page = s.pageIndex
        stage = s.stageId
        action = s.action.opcode
        element = s.control.map { String($0.displayText.prefix(60)) }
        concept = s.control?.concept
        confidence = s.matchScore
        value = s.valueRef
        urlBefore = s.urlBefore
        urlAfter = s.urlAfter
        status = s.status
        durationMs = s.durationMs
        result = s.result
    }
}

public struct RunResult: Sendable {
    public var outcome: Outcome
    public var reason: String?
    public var requiredConcept: String?
    public var failedStageId: String?
    public var failedActionIndex: Int?
    public var trace: [TraceStep] = []
    public var pages: [CapturedPage] = []
    public var network: [NetworkEntry] = []
    public var secretsUsed: [SensitiveValue] = []
    public var durationMs: Int = 0
    public var modelCalls: Int = 0
}
