import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
}

/// Zeilendiff zweier Recipes (kürzeste gemeinsame Teilfolge) für die Diff-Ansicht alt/neu.
public enum RecipeDiff {
    public static func lines(old: String, new: String) -> [DiffLine] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { out.append(.init(kind: .same, text: a[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.init(kind: .removed, text: a[i])); i += 1 }
            else { out.append(.init(kind: .added, text: b[j])); j += 1 }
        }
        while i < a.count { out.append(.init(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { out.append(.init(kind: .added, text: b[j])); j += 1 }
        return out
    }

    public static func changeCount(_ lines: [DiffLine]) -> Int { lines.filter { $0.kind != .same }.count }
}

public struct ImportPreview: Sendable {
    public var recipe: Recipe?
    public var issues: [String]
    public var diff: [DiffLine]
    /// Passt die Datei zum Profil (profileId oder SSID)?
    public var matchesProfile: Bool

    public var isValid: Bool { recipe != nil && issues.isEmpty }
}

/// "Recipe importieren" (SPEC §3.3): Parse, Schema, Security-Validator, Diff alt/neu, dann
/// erst nach Bestätigung eine neue Revision.
public enum RecipeImporter {
    public static func prepare(yaml: String, for profile: PortalProfile) -> ImportPreview {
        do {
            let recipe = try PRLCodec.parse(yaml: yaml)
            let issues = SecurityValidator.errors(recipe, bindings: profile.credentialBindings).map(\.description)
            let old = profile.recipe.flatMap { try? PRLCodec.serialize($0) } ?? ""
            let new = try PRLCodec.serialize(recipe)
            let matches = recipe.profileId == profile.id.uuidString
                || (recipe.profileId == nil && recipe.ssid == profile.network.ssidExact)
                || recipe.ssid == profile.network.ssidExact
            return ImportPreview(recipe: issues.isEmpty ? recipe : nil, issues: issues,
                                 diff: RecipeDiff.lines(old: old, new: new), matchesProfile: matches)
        } catch {
            return ImportPreview(recipe: nil, issues: [String(describing: error)], diff: [], matchesProfile: false)
        }
    }

    public enum ApplyError: Error, Equatable, Sendable { case invalid }

    public static func apply(_ preview: ImportPreview, to profile: PortalProfile, at date: Date = Date()) throws -> PortalProfile {
        guard preview.isValid, var recipe = preview.recipe else { throw ApplyError.invalid }
        recipe.profileId = profile.id.uuidString
        var p = profile
        p.commit(recipe, note: "Import", at: date)
        return p
    }
}

/// Stabilitätsmetrik pro Profil (SPEC §3.3). "Stabil" ab 5 Erfolgen in Folge ohne Lernen oder Reparatur.
public struct StabilityMetrics: Equatable, Sendable {
    public var totalRuns: Int
    public var successes: Int
    public var successRate: Double
    public var lastOutcomes: [Outcome]
    public var streak: Int
    public var isStable: Bool

    public static let stableThreshold = 5

    public init(logs: [RunLog]) {
        let sorted = logs.sorted { $0.startedAt > $1.startedAt }
        totalRuns = sorted.count
        successes = sorted.filter { $0.outcome == .success }.count
        successRate = totalRuns == 0 ? 0 : Double(successes) / Double(totalRuns)
        lastOutcomes = sorted.prefix(10).map(\.outcome)
        var s = 0
        for l in sorted {
            guard l.outcome == .success, !l.repaired else { break }
            // Ein Lernlauf zählt als Erfolg, setzt aber die Serie auf diese Revision.
            s += 1
            if l.learned { break }
        }
        streak = s
        isStable = s >= Self.stableThreshold
    }
}
