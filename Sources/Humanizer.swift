// Humanizer — rule-based port of the deterministic subset of github.com/blader/humanizer.
// Strips AI writing "tells" that can be removed with reliable find/replace:
// em/en dashes, filler phrases, hedging, copula-avoidance, overused AI vocabulary,
// signposting, chatbot artifacts, curly quotes, emojis, and bold markdown.
// Semantic rewrites (significance inflation, vague attribution, rule-of-three, etc.)
// need an LLM and are intentionally NOT attempted here.

import Foundation

enum Humanizer {
    private static func rx(_ s: String, _ p: String, _ t: String) -> String {
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, options: [],
                                            range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    // Ordered find→replace rules (case-insensitive; sentence-start capitalization fixed at the end).
    private static let rules: [(String, String)] = [
        // Filler phrases (#23)
        ("\\bin order to\\b", "to"),
        ("\\bdue to the fact that\\b", "because"),
        ("\\bdue to the fact\\b", "because"),
        ("\\bat this point in time\\b", "now"),
        ("\\bin the event that\\b", "if"),
        ("\\bhad the ability to\\b", "could"),
        ("\\b(?:has|have) the ability to\\b", "can"),
        ("\\bit'?s important to note that\\s*", ""),
        ("\\bit is important to note that\\s*", ""),
        ("\\bin today'?s rapidly evolving landscape,?\\s*", ""),
        // Hedging (#24)
        ("\\bcould potentially possibly\\b", "may"),
        ("\\bcould potentially\\b", "may"),
        ("\\b(?:it )?could be argued that\\s*", ""),
        ("\\bmay somewhat\\b", "may"),
        ("\\bmight have some effect\\b", "may have an effect"),
        // Copula avoidance (#8)
        ("\\bserves as\\b", "is"),
        ("\\bserve as\\b", "are"),
        ("\\bstands as\\b", "is"),
        ("\\bstand as\\b", "are"),
        ("\\bboasts (a|an|the)\\b", "has $1"),
        ("\\bboast (a|an|the)\\b", "have $1"),
        // Overused AI vocabulary (#7, #4)
        ("\\butilizes\\b", "uses"),
        ("\\butilizing\\b", "using"),
        ("\\butilized\\b", "used"),
        ("\\butilize\\b", "use"),
        ("\\bleverages\\b", "uses"),
        ("\\bleveraging\\b", "using"),
        ("\\bleveraged\\b", "used"),
        ("\\bleverage\\b", "use"),
        ("\\bdelve into\\b", "examine"),
        ("\\bdelve\\b", "examine"),
        ("\\bin the heart of\\b", "in"),
        ("\\bnestled (?:in|within)\\b", "in"),
        ("\\badditionally\\b,?", "also,"),
        ("\\bmoreover\\b,?", "also,"),
        ("\\bfurthermore\\b,?", "also,"),
        // Signposting & announcements (#28)
        ("\\b(?:let'?s dive in(?:to it)?|let'?s explore|let'?s break this down|here'?s what you need to know|without further ado|now let'?s look at|let'?s get started)\\b[\\s,:.]*", ""),
        // Conversational openers, sentence-initial, comma required (#33)
        ("(^|[.!?]\\s+|\\n)(?:honestly|look|here'?s the thing|the thing is|let'?s be honest)[,:]\\s+", "$1"),
        // Sycophancy / chatbot artifacts (#20, #22)
        ("\\b(?:great question|that'?s an excellent point|you'?re absolutely right|i hope this helps|hope this helps|let me know if you (?:have any questions|need anything|have questions))\\b[!.,]*\\s*", ""),
        ("(^|[.!?]\\s+|\\n)(?:of course|certainly|sure|absolutely)[!,.]\\s+", "$1"),
        // Persuasive authority tropes (#27)
        ("\\b(?:at its core|in reality|fundamentally|the real question is|what really matters is|the heart of the matter is)\\b[,:]?\\s*", ""),
    ]

    static func humanize(_ input: String) -> String {
        var s = input
        // Curly quotes → straight (#19)
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        // Bold markdown (#15)
        s = rx(s, "\\*\\*(.+?)\\*\\*", "$1")
        s = rx(s, "__(.+?)__", "$1")
        // Emojis (#18)
        s = removeEmoji(s)
        // Dashes (#14): keep numeric ranges as hyphen, else → comma
        s = rx(s, "(\\d)\\s*[\u{2013}\u{2014}]\\s*(\\d)", "$1-$2")
        s = rx(s, "\\s*[\u{2013}\u{2014}]\\s*", ", ")
        // Ordered phrase rules
        for (p, t) in rules { s = rx(s, p, t) }
        s = cleanup(s)
        s = capitalizeSentences(s)
        return s
    }

    private static func removeEmoji(_ s: String) -> String {
        let ranges: [ClosedRange<UInt32>] = [
            0x1F300...0x1FAFF, 0x1F000...0x1F0FF, 0x2600...0x27BF,
            0x2B00...0x2BFF, 0xFE00...0xFE0F, 0x1F1E6...0x1F1FF
        ]
        let extra: Set<UInt32> = [0x200D, 0x20E3, 0x2122, 0x2139, 0x2194, 0x2195, 0x2B05, 0x2B06, 0x2B07]
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if ranges.contains(where: { $0.contains(u.value) }) || extra.contains(u.value) { continue }
            out.append(u)
        }
        return String(out)
    }

    private static func cleanup(_ input: String) -> String {
        var s = input
        s = rx(s, " +([,.;:!?])", "$1")     // space before punctuation
        s = rx(s, ",( *,)+", ",")           // doubled commas
        s = rx(s, ",( *)\\.", ".")          // comma then period
        s = rx(s, "[ \\t]{2,}", " ")        // collapse runs of spaces
        s = rx(s, "(?m)^[ \\t]+", "")       // leading line whitespace
        s = rx(s, "(?m)[ \\t]+$", "")       // trailing line whitespace
        s = rx(s, "\\n{3,}", "\n\n")        // 3+ blank lines → 1
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeSentences(_ input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(^|[.!?]\\s+|\\n\\s*)([a-z])", options: []) else { return input }
        let ns = input as NSString
        let result = NSMutableString(string: input)
        for m in re.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length)).reversed() {
            let r = m.range(at: 2)
            result.replaceCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return result as String
    }
}
