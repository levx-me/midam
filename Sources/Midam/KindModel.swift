import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Picks a document kind with the on-device Foundation Models (macOS 26 with Apple Intelligence on).
/// Elsewhere `available` is false and `classify` returns nil, so the rules decide.
enum KindModel {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static func classify(title: String, excerpt: String) async -> DocKind? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "Title: \(title.prefix(200))\nOpening: \(excerpt.prefix(600))\nKind ID:"
            guard let answer = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0, maximumResponseTokens: 8)) else { return nil }
            return parse(answer.content)
        }
        #endif
        return nil
    }

    /// The first word of the answer, if it is one of the IDs.
    static func parse(_ answer: String) -> DocKind? {
        let word = answer.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        return DocKind(rawValue: word)
    }

    private static let instructions = """
    You sort Markdown documents that coding agents wrote. Read the title and opening text, in any \
    language, and answer with exactly one ID from this list and nothing else:
    design: product or technical design, spec, PRD, requirements, architecture, decision record
    plan: plan, roadmap, task list, milestones, schedule
    research: research, investigation, report, survey, analysis, benchmark, comparison
    ops: deployment, release, runbook, incident, operations
    guide: guide, how-to, tutorial, README, reference, glossary, encyclopedia
    handoff: handoff notes for the next person or agent to continue the work
    instructions: instructions or rules for AI agents (CLAUDE.md, AGENTS.md, skills, prompts)
    memory: an agent's saved memory or facts about the user or project
    notes: working notes, logs, scratch thoughts
    other: none of the above
    """
}
