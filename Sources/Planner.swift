// Planner — turns target text into a flat keystroke plan ([Op]) that emulates how a
// human actually writes: variable-speed bursts, planning pauses (>=2s), self-corrected
// typos, and — when `revise` is on — a DRAFT pass that leaves small imperfections
// (lowercase sentence-starts, a mistyped word, a dropped comma) followed by a REVISION
// pass that arrows back to each one, fixes it, and returns to the end.
//
// Grounded in keystroke-logging writing research (P-bursts / R-bursts, ~200ms cognitive
// pause threshold, longer pauses at sentence boundaries).
//
// Pure Foundation (no AppKit) so the index/navigation logic is unit-testable: applying
// the produced ops to a TextModel always reproduces the target text exactly.

import Foundation

// MARK: math + keyboard adjacency (used for believable typos)

func gaussian(_ mean: Double, _ sd: Double) -> Double {
    let u1 = Double.random(in: 1e-12 ..< 1.0)
    let u2 = Double.random(in: 0.0 ..< 1.0)
    return mean + (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2) * sd
}

private let adjacency: [Character: String] = [
    "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "rygf",
    "y": "tuhg", "u": "yijh", "i": "uokj", "o": "iplk", "p": "ol",
    "a": "qwsz", "s": "weadzx", "d": "ersfcx", "f": "rtdgvc", "g": "tyfhbv",
    "h": "yugjnb", "j": "uihknm", "k": "iojlm", "l": "opk",
    "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn",
    "n": "bhjm", "m": "njk"
]
func wrongKey(for c: Character) -> Character {
    let lower = Character(c.lowercased())
    guard let n = adjacency[lower], let p = n.randomElement() else { return c }
    return c.isUppercase ? Character(p.uppercased()) : p
}

// MARK: keystroke model

enum Key: Equatable {
    case ch(Character)   // insert a character at the caret
    case backspace       // delete the character before the caret
    case left            // move caret left one
    case right           // move caret right one
    case noop            // pure pause (no keystroke)
}

struct Op {
    let key: Key
    let delay: Double    // seconds to wait AFTER this keystroke
}

struct TextModel {
    var chars: [Character] = []
    var caret: Int = 0
    mutating func apply(_ k: Key) {
        switch k {
        case .ch(let c): chars.insert(c, at: caret); caret += 1
        case .backspace: if caret > 0 { chars.remove(at: caret - 1); caret -= 1 }
        case .left: if caret > 0 { caret -= 1 }
        case .right: if caret < chars.count { caret += 1 }
        case .noop: break
        }
    }
    var text: String { String(chars) }
}

struct PlanSettings {
    var minWPM: Double = 35
    var maxWPM: Double = 75
    var typoRate: Double = 0.03
    var humanize: Bool = true
    var maxHuman: Bool = false
    var revise: Bool = false
}

// MARK: planner

final class Planner {
    private let s: PlanSettings
    private let target: [Character]
    private var ops: [Op] = []
    private var model = TextModel()
    private var wpm: Double

    private enum RevKind { case capitalize(Character); case replace(Character); case insert(Character) }
    private struct Rev { let index: Int; let kind: RevKind }
    private var revs: [Rev] = []

    init(target: String, settings: PlanSettings) {
        self.target = Array(target)
        self.s = settings
        self.wpm = (settings.minWPM + settings.maxWPM) / 2
    }

    func plan() -> [Op] {
        ops.removeAll(); revs.removeAll(); model = TextModel()
        wpm = (s.minWPM + s.maxWPM) / 2
        draftPass()
        if s.revise { revisionPass() }
        return ops
    }

    private func emit(_ k: Key, _ delay: Double) { ops.append(Op(key: k, delay: delay)); model.apply(k) }

    // MARK: timing (research-informed)

    private func advanceSpeed(wordBoundary: Bool) {
        let span = max(1.0, s.maxWPM - s.minWPM)
        let center = (s.minWPM + s.maxWPM) / 2
        let drift = wordBoundary ? (s.maxHuman ? 0.18 : 0.14) : (s.maxHuman ? 0.08 : 0.06)
        wpm += gaussian(0, span * drift)
        wpm += (center - wpm) * 0.05
        if wordBoundary && Double.random(in: 0..<1) < (s.maxHuman ? 0.18 : 0.10) {
            wpm = Double.random(in: s.minWPM...s.maxWPM)
        }
        wpm = min(s.maxWPM, max(s.minWPM, wpm))
    }

    private func charDelay(at i: Int) -> Double {
        let cps = max(0.5, wpm * 5.0 / 60.0)
        let mean = 1.0 / cps
        let fatigue = s.humanize ? min(0.25, Double(i) / Double(max(1, target.count)) * 0.22) : 0.0
        if !s.humanize { return mean * (1.0 + fatigue) }
        return max(mean * 0.3, gaussian(mean, mean * (s.maxHuman ? 0.5 : 0.4))) * (1.0 + fatigue)
    }

    private func pauseAfter(_ c: Character) -> Double {
        guard s.humanize else { return 0 }
        let mh = s.maxHuman
        var e = 0.0
        if ".!?".contains(c) {
            e += max(0.12, gaussian(mh ? 0.85 : 0.5, mh ? 0.45 : 0.28))
            if Double.random(in: 0..<1) < (mh ? 0.20 : 0.10) { e += max(0.8, gaussian(2.6, 1.1)) } // re-read
        } else if ",;:".contains(c) {
            e += max(0.05, gaussian(mh ? 0.32 : 0.18, 0.1))
        } else if c == " " {
            if Double.random(in: 0..<1) < (mh ? 0.16 : 0.07) { e += max(0.1, gaussian(mh ? 1.0 : 0.7, mh ? 0.7 : 0.5)) }
            if Double.random(in: 0..<1) < (mh ? 0.09 : 0.05) { e += max(1.6, gaussian(2.3, 0.8)) }   // P-burst planning pause (>=2s)
        } else if c == "\n" {
            e += max(0.15, gaussian(mh ? 0.9 : 0.55, 0.4))
        }
        if Double.random(in: 0..<1) < (mh ? 0.03 : 0.012) { e += max(0.2, gaussian(mh ? 1.7 : 1.1, 0.8)) }
        return e
    }

    // MARK: draft pass

    private func draftPass() {
        var capSet = Set<Int>(), commaSet = Set<Int>(), typoSet = Set<Int>()
        if s.revise && s.humanize { (capSet, commaSet, typoSet) = chooseImperfections() }

        var i = 0
        while i < target.count {
            let c = target[i]
            advanceSpeed(wordBoundary: c == " " || c == "\n")

            if capSet.contains(i) {
                // Forgot to capitalize a sentence start; fix it in revision.
                let lc = Character(c.lowercased())
                revs.append(Rev(index: model.caret, kind: .capitalize(c)))
                emit(.ch(lc), charDelay(at: i) + pauseAfter(lc))
            } else if commaSet.contains(i) {
                // Dropped a comma; insert it in revision. (Don't type anything now.)
                revs.append(Rev(index: model.caret, kind: .insert(c)))
            } else if typoSet.contains(i) {
                // A mistyped word left uncorrected in the draft; fix it in revision.
                revs.append(Rev(index: model.caret, kind: .replace(c)))
                emit(.ch(wrongKey(for: c)), charDelay(at: i) + pauseAfter(c))
            } else if s.humanize, c.isLetter, Double.random(in: 0..<1) < s.typoRate {
                immediateTypo(c, at: i)
            } else {
                emit(.ch(c), charDelay(at: i) + pauseAfter(c))
            }
            i += 1
        }
    }

    /// Typos noticed and fixed within the same burst (length-neutral).
    private func immediateTypo(_ c: Character, at i: Int) {
        if Double.random(in: 0..<1) < 0.6 {
            // adjacent wrong key, fixed immediately
            emit(.ch(wrongKey(for: c)), max(0.10, gaussian(0.28, 0.12)))
            emit(.backspace, max(0.05, gaussian(0.12, 0.05)))
            emit(.ch(c), charDelay(at: i) + pauseAfter(c))
        } else {
            // doubled letter, deleted
            emit(.ch(c), charDelay(at: i))
            emit(.ch(c), max(0.06, gaussian(0.16, 0.07)))
            emit(.backspace, max(0.08, gaussian(0.22, 0.10)) + pauseAfter(c))
        }
    }

    private func chooseImperfections() -> (Set<Int>, Set<Int>, Set<Int>) {
        var caps: [Int] = [], commas: [Int] = [], typos: [Int] = []
        var lastSig: Character = "."
        for (i, c) in target.enumerated() {
            let sentenceStart = (lastSig == "." || lastSig == "!" || lastSig == "?")
            if c.isLetter && c.isUppercase && sentenceStart { caps.append(i) }
            else if c == "," { commas.append(i) }
            else if c.isLetter && !sentenceStart && wrongKey(for: c) != c { typos.append(i) }
            if !c.isWhitespace { lastSig = c }
        }
        caps.shuffle(); commas.shuffle(); typos.shuffle()
        var chosen: [(Int, Int)] = []
        chosen += caps.prefix(2).map { ($0, 0) }
        chosen += commas.prefix(2).map { ($0, 1) }
        chosen += typos.prefix(3).map { ($0, 2) }
        chosen.shuffle()
        let budget = max(2, min(6, target.count / 110))
        chosen = Array(chosen.prefix(budget))
        return (Set(chosen.filter { $0.1 == 0 }.map { $0.0 }),
                Set(chosen.filter { $0.1 == 1 }.map { $0.0 }),
                Set(chosen.filter { $0.1 == 2 }.map { $0.0 }))
    }

    // MARK: revision pass

    private func revisionPass() {
        guard !revs.isEmpty else { return }
        emit(.noop, max(1.0, gaussian(2.0, 0.7)))   // sit back and re-read

        // Process from the end backwards so earlier indices stay valid as we edit.
        for r in revs.sorted(by: { $0.index > $1.index }) {
            switch r.kind {
            case .insert(let ch):
                navigate(to: r.index)
                emit(.noop, max(0.15, gaussian(0.5, 0.25)))       // found the spot
                emit(.ch(ch), max(0.08, gaussian(0.18, 0.07)))    // add the missing character
            case .capitalize(let correct), .replace(let correct):
                // Delete the whole wrong word and retype it correctly — a visible, real fix.
                let i = r.index
                var ws = i; while ws > 0 && model.chars[ws - 1].isLetter { ws -= 1 }
                var we = i; while we < model.chars.count && model.chars[we].isLetter { we += 1 }
                var word = Array(model.chars[ws..<we])
                let local = i - ws
                if local >= 0 && local < word.count { word[local] = correct }
                navigate(to: we)                                  // caret to the end of the word
                emit(.noop, max(0.15, gaussian(0.5, 0.25)))       // found it
                for _ in 0..<(we - ws) { emit(.backspace, max(0.03, gaussian(0.09, 0.04))) }  // delete the word
                for c in word { emit(.ch(c), max(0.05, gaussian(0.12, 0.05))) }               // retype it correctly
            }
            emit(.noop, max(0.10, gaussian(0.35, 0.18)))   // short revision pause
        }
        navigate(to: model.chars.count)   // return to the end
    }

    private func navigate(to idx: Int) {
        while model.caret > idx { emit(.left, max(0.012, gaussian(0.028, 0.012))) }
        while model.caret < idx { emit(.right, max(0.012, gaussian(0.028, 0.012))) }
    }
}
