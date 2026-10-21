import Foundation
import FoundationModels
import NaturalLanguage

enum Verdict: String {
    case study, neutral, distraction
}

struct Judgement: Equatable {
    enum Source: String { case you = "your lists", rules = "built-in list", ai = "Apple Intelligence", guess = "keywords" }
    var verdict: Verdict
    var reason: String
    var source: Source
}

/// Decides whether the current app / tab is study-related.
/// Order: your lists → built-in lists → Apple Intelligence (on-device) → simple keyword rules.
/// Results are cached in memory for the session only.
@MainActor
final class RelevanceJudge {
    private var cache: [String: Judgement] = [:]
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    var aiAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var engineDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Apple Intelligence (on-device)"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Built-in rules (Apple Intelligence is off)"
        case .unavailable(.modelNotReady):
            return "Built-in rules (Apple Intelligence model downloading)"
        case .unavailable:
            return "Built-in rules"
        }
    }

    func reset() { cache.removeAll() }

    /// New topic: drop automatic verdicts but keep what you marked by hand.
    func resetKeepingOverrides() { cache = cache.filter { $0.value.source == .you } }

    func cached(_ s: ActivitySnapshot) -> Judgement? { cache[s.key] }

    func override(_ s: ActivitySnapshot, as verdict: Verdict) {
        cache[s.key] = Judgement(verdict: verdict, reason: "Marked by you", source: .you)
    }

    func prewarm() {
        if aiAvailable { LanguageModelSession().prewarm() }
    }

    func judge(_ s: ActivitySnapshot, topic: String) async -> Judgement {
        if let hit = cache[s.key] { return hit }
        let result = await evaluate(s, topic: topic)
        if let hit = cache[s.key], hit.source == .you { return hit } // marked by you while we were checking
        if !Task.isCancelled { cache[s.key] = result }
        return result
    }

    // MARK: - Pipeline

    private func evaluate(_ s: ActivitySnapshot, topic: String) async -> Judgement {
        let settings = AppSettings.shared
        if settings.alwaysStudyEntries.contains(where: { Lists.matches($0, s) }) {
            return Judgement(verdict: .study, reason: "In Always Study list", source: .you)
        }
        if settings.alwaysDistractingEntries.contains(where: { Lists.matches($0, s) }) {
            return Judgement(verdict: .distraction, reason: "In Always Distraction list", source: .you)
        }

        if s.isBrowser {
            guard let domain = s.domain else {
                return Judgement(verdict: .neutral, reason: "No page", source: .rules)
            }
            if Lists.inList(domain, Lists.distractionDomains) {
                return Judgement(verdict: .distraction, reason: "Entertainment or social site", source: .rules)
            }
            if Lists.inList(domain, Lists.studyDomains) {
                return Judgement(verdict: .study, reason: "Reference or study site", source: .rules)
            }
            if Lists.inList(domain, ["localhost", "127.0.0.1"]) || s.url?.hasPrefix("file:") == true {
                return Judgement(verdict: .neutral, reason: "Local file", source: .rules)
            }
        } else {
            if Lists.studyApps.contains(s.bundleID) {
                return Judgement(verdict: .study, reason: "Study app", source: .rules)
            }
            if Lists.distractionApps.contains(s.bundleID) {
                return Judgement(verdict: .distraction, reason: "Messaging or entertainment app", source: .rules)
            }
            if Lists.neutralApps.contains(s.bundleID) {
                return Judgement(verdict: .neutral, reason: "Utility app", source: .rules)
            }
        }

        if aiAvailable, let ai = await askAI(s, topic: topic) { return ai }
        return heuristic(s, topic: topic)
    }

    private func askAI(_ s: ActivitySnapshot, topic: String) async -> Judgement? {
        let instructions = """
        You help a student stay focused. They are studying: "\(topic)".
        You are told which app is in front of them and, for web browsers, the website and page title.
        Classify it with exactly one word, then " - " and a reason of at most 8 words:
        STUDY: related to their topic, or a general study tool (notes, documents, textbooks, search or videos about the topic, coding for it).
        NEUTRAL: a harmless utility that is neither (file manager, settings, calendar, music player, login page, empty tab).
        DISTRACTION: entertainment, social media, games, shopping, sport, news, messaging or videos unrelated to the topic.
        """
        var prompt = "App: \(s.appName)"
        if let domain = s.domain { prompt += "\nWebsite: \(domain)" }
        if let title = s.title, !title.isEmpty { prompt += "\nPage title: \(title.prefix(200))" }

        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 30)
        // Give up after 12 s without waiting for the model to finish.
        let reply: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let work = Task { once.resume(try? await session.respond(to: prompt, options: options).content) }
            Task {
                try? await Task.sleep(for: .seconds(12))
                work.cancel()
                once.resume(nil)
            }
        }
        guard let reply, !Task.isCancelled else { return nil }

        // Earliest verdict word wins, so "**STUDY** - ..." still parses.
        let upper = reply.uppercased()
        let candidates: [(Verdict, String)] = [(.study, "STUDY"), (.neutral, "NEUTRAL"), (.distraction, "DISTRACTION")]
        guard let (verdict, word) = candidates
            .compactMap({ v, w in upper.range(of: w).map { (v, w, $0.lowerBound) } })
            .min(by: { $0.2 < $1.2 })
            .map({ ($0.0, $0.1) }) else { return nil }

        var reason = reply
        if let wordRange = upper.range(of: word) {
            reason = String(reply[wordRange.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " *:-–—\n\t"))
        }
        if reason.isEmpty { reason = verdict.rawValue.capitalized }
        return Judgement(verdict: verdict, reason: reason, source: .ai)
    }

    /// Fallback without Apple Intelligence. Deliberately cautious: when unsure it says "neutral" so you're not nagged.
    private func heuristic(_ s: ActivitySnapshot, topic: String) -> Judgement {
        guard s.isBrowser, let title = s.title?.lowercased(), !title.isEmpty else {
            return Judgement(verdict: .neutral, reason: "Unclassified", source: .guess)
        }
        let topicWords = Lists.significantWords(topic)
        let titleWords = Lists.significantWords(title)
        if topicWords.contains(where: { t in titleWords.contains { $0.hasPrefix(String(t.prefix(5))) } }) {
            return Judgement(verdict: .study, reason: "Title matches topic", source: .guess)
        }
        if Lists.studyKeywords.contains(where: title.contains) {
            return Judgement(verdict: .study, reason: "Educational title", source: .guess)
        }
        if Lists.entertainmentKeywords.contains(where: title.contains) {
            return Judgement(verdict: .distraction, reason: "Entertainment title", source: .guess)
        }
        if !topic.isEmpty, let embedding, embedding.distance(between: topic.lowercased(), and: title) < 1.0 {
            return Judgement(verdict: .study, reason: "Similar to topic", source: .guess)
        }
        if let domain = s.domain, Lists.inList(domain, Lists.rabbitHoleDomains) {
            return Judgement(verdict: .distraction, reason: "Unrelated to topic", source: .guess)
        }
        return Judgement(verdict: .neutral, reason: "Unclassified", source: .guess)
    }
}

/// Resumes a continuation exactly once, from whichever side finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ c: CheckedContinuation<String?, Never>) { continuation = c }
    func resume(_ value: String?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

enum Lists {
    static let distractionDomains: Set<String> = [
        "instagram.com", "tiktok.com", "facebook.com", "x.com", "twitter.com", "threads.net", "bsky.app",
        "snapchat.com", "pinterest.com", "tumblr.com", "9gag.com", "buzzfeed.com",
        "netflix.com", "twitch.tv", "primevideo.com", "disneyplus.com", "hulu.com", "max.com", "crunchyroll.com",
        "roblox.com", "poki.com", "crazygames.com", "coolmathgames.com", "chess.com",
        "discord.com", "web.whatsapp.com", "messenger.com", "web.telegram.org",
    ]
    static let studyDomains: Set<String> = [
        "wikipedia.org", "khanacademy.org", "quizlet.com", "scholar.google.com", "arxiv.org", "overleaf.com",
        "docs.google.com", "drive.google.com", "classroom.google.com", "notion.so", "wolframalpha.com", "desmos.com",
        "geogebra.org", "coursera.org", "edx.org", "brilliant.org", "chegg.com", "stackoverflow.com",
        "stackexchange.com", "developer.mozilla.org", "instructure.com", "blackboard.com", "sparknotes.com",
        "physicsandmathstutor.com", "savemyexams.com", "senecalearning.com", "mathsgenie.co.uk", "corbettmaths.com",
        "chatgpt.com", "claude.ai", "gemini.google.com", "anki.net", "ankiweb.net", "jstor.org", "pubmed.ncbi.nlm.nih.gov",
    ]
    /// Sites that can be study or a rabbit hole; without AI these count as distractions unless the title looks related.
    static let rabbitHoleDomains: Set<String> = ["youtube.com", "reddit.com", "twitch.tv", "amazon.com", "ebay.com"]

    static let studyApps: Set<String> = [
        "com.apple.Notes", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers",
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.onenote.mac",
        "notion.id", "md.obsidian", "net.ankiweb.dtop", "com.goodnotesapp.x", "org.zotero.zotero",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
        "com.googlecode.iterm2", "com.apple.TextEdit", "com.apple.calculator", "com.apple.grapher",
        "com.wolfram.Mathematica", "com.mathworks.matlab", "com.rstudio.desktop", "com.adobe.Reader", "com.apple.iBooksX",
    ]
    static let distractionApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "com.facebook.archon", "com.valvesoftware.steam", "com.apple.TV", "com.roblox.RobloxPlayer",
        "com.mojang.minecraftlauncher", "net.battle.app", "com.epicgames.EpicGamesLauncher", "com.apple.Arcade",
    ]
    static let neutralApps: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.Music", "com.spotify.client", "com.apple.iCal",
        "com.apple.reminders", "com.apple.ActivityMonitor", "com.apple.loginwindow", "com.apple.Spotlight",
    ]

    static let studyKeywords = [
        "lecture", "tutorial", "explained", "course", "lesson", "revision", "exam", "homework", "worksheet",
        "past paper", "textbook", "practice questions", "how to solve", "study", "notes", "crash course",
    ]
    static let entertainmentKeywords = [
        "trailer", "funny", "meme", "highlights", "reaction", "official music video", "official video", "episode",
        "gameplay", "let's play", "shorts", "compilation", "prank", "vlog", "livestream", "live stream", "unboxing",
    ]
    private static let stopWords: Set<String> = ["about", "with", "from", "that", "this", "your", "what", "into", "study", "studying"]

    static func inList(_ domain: String, _ list: Set<String>) -> Bool {
        list.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Matches a user list entry against a domain, bundle ID or app name.
    static func matches(_ entry: String, _ s: ActivitySnapshot) -> Bool {
        if let domain = s.domain, domain == entry || domain.hasSuffix("." + entry) { return true }
        if s.bundleID.lowercased() == entry { return true }
        let app = s.appName.lowercased()
        return app == entry || (entry.count >= 3 && !s.isBrowser && app.contains(entry))
    }

    static func significantWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
    }

    static func isRabbitHole(_ s: ActivitySnapshot) -> Bool {
        guard let domain = s.domain else { return false }
        return inList(domain, rabbitHoleDomains) || domain.hasSuffix("google.com") || domain.hasPrefix("google.")
    }
}
