// DripWriter — human-like auto-typer for macOS
// Variable-speed typing (wpm drifts between min/max), pauses, fatigue, self-corrected
// typos, a one-click Humanize pass, preset modes (Steady / Natural / Max Human), and a
// compact window mode. AppKit, no runtime deps. Types via CGEvent; needs Accessibility.

import Cocoa
import CoreGraphics

// MARK: - Palette (blue + black, OLED dark)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let cBgTop      = rgb(0x10, 0x1A, 0x30)
let cBgBot      = rgb(0x06, 0x0B, 0x16)
let cSurface    = rgb(0x0E, 0x16, 0x28)
let cSurfaceHi  = rgb(0x17, 0x22, 0x3C)
let cEditor     = rgb(0x13, 0x1F, 0x39)   // lighter than bg so the field reads as a field
let cBorder     = rgb(0x1E, 0x2A, 0x44)
let cBorderHi   = rgb(0x3A, 0x4A, 0x68)
let cText       = rgb(0xF1, 0xF5, 0xF9)
let cMuted      = rgb(0x8B, 0x9C, 0xB6)
let cBlue       = rgb(0x3B, 0x82, 0xF6)
let cBlueBright = rgb(0x60, 0xA5, 0xFA)
let cBlueDeep   = rgb(0x1D, 0x4E, 0xD8)
let cTrackOff   = rgb(0x2A, 0x35, 0x4D)

// MARK: - Key codes

private let kBackspace: CGKeyCode = 51
private let kReturn: CGKeyCode    = 36
private let kTab: CGKeyCode       = 48
private let kEscape: UInt16       = 53

// MARK: - Math

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

// MARK: - Humanizer lives in Humanizer.swift

// MARK: - Atomic flag

final class Atomic {
    private let lock = NSLock()
    private var v: Bool
    init(_ x: Bool) { v = x }
    var get: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
}

// MARK: - Typing engine (variable WPM)

final class TypingEngine {
    var minWPM: Double = 35
    var maxWPM: Double = 75
    var typoRate: Double = 0.03
    var humanize: Bool = true
    var newlineAsReturn: Bool = true
    var maxHuman: Bool = false        // intensifies drift / pauses

    var onProgress: ((Double) -> Void)?
    var onFinished: ((_ completed: Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private var currentWPM: Double = 55
    private let queue = DispatchQueue(label: "com.natep.dripwriter.typing")
    private let running = Atomic(false)
    private let source = CGEventSource(stateID: .hidSystemState)
    private let ownBundleID = Bundle.main.bundleIdentifier

    var isRunning: Bool { running.get }
    func stop() { running.set(false) }

    func start(text: String) {
        let chars = Array(text)
        guard !chars.isEmpty else { onFinished?(true); return }
        currentWPM = (minWPM + maxWPM) / 2
        running.set(true)
        queue.async { [weak self] in
            guard let self = self else { return }
            let done = self.run(chars)
            self.running.set(false)
            DispatchQueue.main.async { self.onFinished?(done) }
        }
    }

    private func postUnicode(_ s: String) {
        let u = Array(s.utf16)
        u.withUnsafeBufferPointer { buf in
            if let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                d.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                d.post(tap: .cghidEventTap)
            }
            usleep(UInt32.random(in: 6000...18000))
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.post(tap: .cghidEventTap)
            }
        }
    }
    private func postKey(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(UInt32.random(in: 6000...16000))
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
    private func typeChar(_ c: Character) {
        if c == "\n" || c == "\r" { newlineAsReturn ? postKey(kReturn) : postUnicode("\n") }
        else if c == "\t" { postKey(kTab) }
        else { postUnicode(String(c)) }
    }
    private func backspace() { postKey(kBackspace) }
    private func sleep(_ s: Double) { if s > 0 { Thread.sleep(forTimeInterval: s) } }

    private func updateSpeed(wordBoundary: Bool) {
        let span = max(1.0, maxWPM - minWPM)
        let center = (minWPM + maxWPM) / 2
        let drift = wordBoundary ? (maxHuman ? 0.18 : 0.14) : (maxHuman ? 0.08 : 0.06)
        currentWPM += gaussian(0, span * drift)
        currentWPM += (center - currentWPM) * 0.05
        if wordBoundary && Double.random(in: 0..<1) < (maxHuman ? 0.18 : 0.10) {
            currentWPM = Double.random(in: minWPM...maxWPM)
        }
        currentWPM = min(maxWPM, max(minWPM, currentWPM))
    }
    private func charDelay(fatigue: Double) -> Double {
        let cps = max(0.5, currentWPM * 5.0 / 60.0)
        let mean = 1.0 / cps
        if !humanize { return mean * (1.0 + fatigue) }
        return max(mean * 0.3, gaussian(mean, mean * (maxHuman ? 0.5 : 0.4))) * (1.0 + fatigue)
    }
    private func pause(after c: Character) {
        guard humanize else { return }
        let mh = maxHuman
        var e = 0.0
        if ".!?".contains(c) { e += max(0.12, gaussian(mh ? 0.85 : 0.5, mh ? 0.45 : 0.28)) }
        else if ",;:".contains(c) { e += max(0.05, gaussian(mh ? 0.32 : 0.18, 0.1)) }
        else if c == " " { if Double.random(in: 0..<1) < (mh ? 0.16 : 0.07) { e += max(0.1, gaussian(mh ? 1.0 : 0.7, mh ? 0.7 : 0.5)) } }
        else if c == "\n" { e += max(0.15, gaussian(mh ? 0.9 : 0.55, 0.4)) }
        if Double.random(in: 0..<1) < (mh ? 0.03 : 0.012) { e += max(0.2, gaussian(mh ? 1.7 : 1.1, 0.8)) }
        // Max Human: occasionally "re-read" after finishing a sentence.
        if mh && ".!?".contains(c) && Double.random(in: 0..<1) < 0.18 { e += max(0.8, gaussian(2.6, 1.1)) }
        sleep(e)
    }
    private func emit(_ c: Character, fatigue: Double) {
        typeChar(c); sleep(charDelay(fatigue: fatigue)); pause(after: c)
    }
    private func frontmostIsSelf() -> Bool {
        var r = false
        let read = { r = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == self.ownBundleID) }
        if Thread.isMainThread { read() } else { DispatchQueue.main.sync(execute: read) }
        return r
    }

    private func run(_ chars: [Character]) -> Bool {
        let count = chars.count
        let deadline = Date().addingTimeInterval(4.0)
        while isRunning && frontmostIsSelf() && Date() < deadline {
            DispatchQueue.main.async { self.onStatus?("Click into your target field…") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.25)

        var i = 0, lastPct = -1
        while i < count {
            if !isRunning { return false }
            if i % 12 == 0 {
                while isRunning && frontmostIsSelf() {
                    DispatchQueue.main.async { self.onStatus?("Paused — click your target field…") }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            if !isRunning { return false }
            let c = chars[i]
            updateSpeed(wordBoundary: c == " " || c == "\n")
            let fatigue = humanize ? min(0.25, Double(i) / Double(max(1, count)) * 0.22) : 0.0
            // Max Human: occasional "false start" — type a few letters of a word, delete, restart.
            if humanize && maxHuman, c.isLetter, (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\n"),
               Double.random(in: 0..<1) < 0.02 {
                var wlen = 0
                while i + wlen < count && chars[i + wlen].isLetter { wlen += 1 }
                let k = min(wlen, Int.random(in: 2...4))
                if k >= 2 {
                    for j in 0..<k { emit(chars[i + j], fatigue: fatigue) }
                    sleep(max(0.25, gaussian(0.6, 0.3)))
                    for _ in 0..<k { backspace(); sleep(max(0.04, gaussian(0.1, 0.05))) }
                    sleep(max(0.15, gaussian(0.4, 0.2)))
                    continue   // i unchanged → the word is typed normally next pass
                }
            }
            if humanize, c.isLetter, Double.random(in: 0..<1) < typoRate {
                i += performTypo(chars, at: i, fatigue: fatigue)
            } else {
                emit(c, fatigue: fatigue); i += 1
            }
            let pct = Int(Double(i) / Double(count) * 100)
            if pct != lastPct { lastPct = pct; DispatchQueue.main.async { self.onProgress?(Double(i) / Double(count)) } }
        }
        return true
    }

    private func performTypo(_ chars: [Character], at index: Int, fatigue: Double) -> Int {
        let c = chars[index]
        let roll = Double.random(in: 0..<1)
        if roll < 0.45 {
            let w = wrongKey(for: c)
            emit(w, fatigue: fatigue)
            sleep(max(0.08, gaussian(0.25, 0.12))); backspace(); sleep(max(0.04, gaussian(0.12, 0.05)))
            emit(c, fatigue: fatigue); return 1
        } else if roll < 0.65 {
            emit(c, fatigue: fatigue)
            typeChar(c); sleep(max(0.05, gaussian(0.16, 0.07))); sleep(max(0.08, gaussian(0.22, 0.1)))
            backspace(); sleep(max(0.04, gaussian(0.1, 0.04))); return 1
        } else if roll < 0.85 {
            let w = wrongKey(for: c)
            emit(w, fatigue: fatigue)
            let maxK = min(3, chars.count - index - 1)
            let k = maxK <= 0 ? 0 : Int.random(in: 1...maxK)
            if k > 0 { for j in 1...k { emit(chars[index + j], fatigue: fatigue) } }
            sleep(max(0.15, gaussian(0.45, 0.2)))
            for _ in 0...k { backspace(); sleep(max(0.03, gaussian(0.09, 0.04))) }
            for j in 0...k { emit(chars[index + j], fatigue: fatigue) }
            return k + 1
        } else {
            if index + 1 < chars.count {
                let n = chars[index + 1]
                emit(n, fatigue: fatigue); emit(c, fatigue: fatigue)
                sleep(max(0.15, gaussian(0.45, 0.2)))
                backspace(); sleep(0.07); backspace(); sleep(0.07)
                emit(c, fatigue: fatigue); emit(n, fatigue: fatigue); return 2
            } else {
                let w = wrongKey(for: c)
                emit(w, fatigue: fatigue); sleep(0.2); backspace(); sleep(0.1); emit(c, fatigue: fatigue); return 1
            }
        }
    }
}

// MARK: - Custom views

final class GradientView: NSView {
    override func draw(_ r: NSRect) { NSGradient(starting: cBgBot, ending: cBgTop)?.draw(in: bounds, angle: 90) }
}

func makeSurface(fill: NSColor, border: NSColor, radius: CGFloat) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = fill.cgColor
    v.layer?.cornerRadius = radius
    v.layer?.borderColor = border.cgColor
    v.layer?.borderWidth = 1
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
}

final class FocusTextView: NSTextView {
    var placeholder = ""
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); onFocusChange?(true); return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); onFocusChange?(false); return r }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: cMuted.withAlphaComponent(0.55)
            ]
            placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
        }
    }
}

final class FancyButton: NSButton {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(_ titleText: String, kind: Kind) {
        super.init(frame: .zero)
        self.kind = kind; self.title = titleText
        isBordered = false; bezelStyle = .regularSquare; setButtonType(.momentaryChange)
        wantsLayer = true; focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        if kind == .primary {
            layer?.shadowColor = cBlue.cgColor; layer?.shadowOpacity = 0.45
            layer?.shadowRadius = 14; layer?.shadowOffset = CGSize(width: 0, height: -2); layer?.masksToBounds = false
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private var fontForKind: NSFont { .systemFont(ofSize: kind == .primary ? 15 : 12.5, weight: .semibold) }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: fontForKind]).width
        return NSSize(width: ceil(w) + (kind == .primary ? 48 : 26), height: kind == .primary ? 50 : 30)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ r: NSRect) {
        let radius: CGFloat = kind == .primary ? 13 : 9
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let filledBlue = (kind == .primary) || selected
        if filledBlue {
            NSGradient(starting: hovering ? cBlueBright : cBlue, ending: cBlueDeep)?.draw(in: path, angle: 90)
            if isHighlighted { rgb(0, 0, 0, 0.20).setFill(); path.fill() }
        } else {
            (hovering ? cSurfaceHi : cSurface).setFill(); path.fill()
            (hovering ? cBlueBright : cBlue).withAlphaComponent(0.85).setStroke(); path.lineWidth = 1; path.stroke()
            if isHighlighted { rgb(0, 0, 0, 0.18).setFill(); path.fill() }
        }
        let ps = NSMutableParagraphStyle(); ps.alignment = .center
        let color: NSColor = filledBlue ? .white : cBlueBright
        let str = NSAttributedString(string: title, attributes: [.font: fontForKind, .foregroundColor: color, .paragraphStyle: ps])
        let sz = str.size()
        str.draw(in: NSRect(x: 0, y: (bounds.height - sz.height) / 2, width: bounds.width, height: sz.height))
    }
}

final class PillToggle: NSControl {
    var isOn = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 26) }
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? cBlue : cTrackOff).setFill(); track.fill()
        if isOn { cBlueBright.withAlphaComponent(0.6).setStroke(); track.lineWidth = 1; track.stroke() }
        let d = bounds.height - 6
        let knob = NSBezierPath(ovalIn: NSRect(x: isOn ? bounds.maxX - d - 3 : 3, y: 3, width: d, height: d))
        NSColor.white.setFill(); knob.fill()
    }
    override func mouseDown(with e: NSEvent) {
        isOn.toggle()
        if let a = action { NSApp.sendAction(a, to: target, from: self) }
    }
}

// MARK: - App

enum RunState { case idle, counting, typing }

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = TypingEngine()
    var window: NSWindow!

    var textView: FocusTextView!
    var editorScroll: NSScrollView!
    var subtitleLabel: NSTextField!
    var controlsPanel: NSView!
    var minSlider: NSSlider!, maxSlider: NSSlider!, typoSlider: NSSlider!, countdownSlider: NSSlider!
    var speedValue: NSTextField!, typoValue: NSTextField!, countdownValue: NSTextField!
    var humanizeToggle: PillToggle!, newlineToggle: PillToggle!
    var modeButtons: [FancyButton] = []
    var startButton: FancyButton!, humanizeButton: FancyButton!, compactButton: FancyButton!
    var statusLabel: NSTextField!
    var progress: NSProgressIndicator!

    var state: RunState = .idle
    var countdownTimer: Timer?, permissionTimer: Timer?
    var remaining = 0
    var didHide = false
    var compact = false
    var maxHumanMode = false
    var globalMonitor: Any?, localMonitor: Any?

    let fullSize = NSSize(width: 600, height: 804)
    let compactSize = NSSize(width: 470, height: 392)

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu(); buildWindow(); installEscMonitors()
        NSApp.activate(ignoringOtherApps: true)
        if !AXIsProcessTrusted() { setStatus("First run: press Start, then switch DripWriter ON in Accessibility settings.") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildWindow() {
        let rect = NSRect(origin: .zero, size: fullSize)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = cBgBot
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = compactSize
        window.center()

        let bg = GradientView(frame: rect)
        bg.autoresizingMask = [.width, .height]
        window.contentView = bg

        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -22),
        ])
        func full(_ v: NSView) { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // Header
        let title = NSTextField(labelWithString: "DripWriter")
        title.font = .systemFont(ofSize: 28, weight: .bold); title.textColor = cText
        stack.addArrangedSubview(title)

        subtitleLabel = NSTextField(wrappingLabelWithString:
            "Drips text into any field with human, variable-speed typing — drifting rhythm, pauses, and self-corrected typos. Press ESC to stop.")
        subtitleLabel.font = .systemFont(ofSize: 12.5); subtitleLabel.textColor = cMuted
        stack.addArrangedSubview(subtitleLabel); full(subtitleLabel)

        // Editor header row: label + Compact + Humanize
        let editorLabel = NSTextField(labelWithString: "YOUR TEXT")
        editorLabel.font = .systemFont(ofSize: 11, weight: .semibold); editorLabel.textColor = cMuted
        compactButton = FancyButton("Compact", kind: .secondary)
        compactButton.target = self; compactButton.action = #selector(toggleCompact)
        humanizeButton = FancyButton("✨ Humanize", kind: .secondary)
        humanizeButton.target = self; humanizeButton.action = #selector(humanizeTapped)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headRow = NSStackView(views: [editorLabel, spacer, compactButton, humanizeButton])
        headRow.orientation = .horizontal; headRow.alignment = .centerY; headRow.spacing = 8
        stack.addArrangedSubview(headRow); full(headRow)

        // Editor (apparent: lighter fill, visible border, placeholder, focus glow)
        editorScroll = NSScrollView()
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 12
        editorScroll.layer?.backgroundColor = cEditor.cgColor
        editorScroll.layer?.borderColor = cBorderHi.cgColor
        editorScroll.layer?.borderWidth = 1.5
        let cs = NSSize(width: 540, height: 150)
        let tv = FocusTextView(frame: NSRect(origin: .zero, size: cs))
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: cs.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false; tv.allowsUndo = true; tv.drawsBackground = false
        tv.textColor = cText; tv.insertionPointColor = cBlueBright
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.selectedTextAttributes = [.backgroundColor: cBlue.withAlphaComponent(0.35), .foregroundColor: NSColor.white]
        tv.placeholder = "Paste or type the text you want dripped in…"
        tv.onFocusChange = { [weak self] focused in
            self?.editorScroll.layer?.borderColor = (focused ? cBlue : cBorderHi).cgColor
            self?.editorScroll.layer?.borderWidth = focused ? 2 : 1.5
        }
        editorScroll.documentView = tv
        textView = tv
        editorScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(editorScroll); full(editorScroll)
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 108).isActive = true

        // Controls panel
        controlsPanel = makeSurface(fill: cSurface, border: cBorder, radius: 14)
        stack.addArrangedSubview(controlsPanel); full(controlsPanel)
        let controls = NSStackView()
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 11
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsPanel.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: controlsPanel.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: controlsPanel.topAnchor, constant: 14),
            controls.bottomAnchor.constraint(equalTo: controlsPanel.bottomAnchor, constant: -14),
        ])
        func pFull(_ v: NSView) { v.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true }

        // Mode selector row
        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = .systemFont(ofSize: 13); modeLabel.textColor = cText
        modeLabel.widthAnchor.constraint(equalToConstant: 88).isActive = true
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        for (i, name) in ["Steady", "Natural", "Max Human"].enumerated() {
            let b = FancyButton(name, kind: .secondary)
            b.tag = i; b.target = self; b.action = #selector(modeTapped(_:))
            modeButtons.append(b)
        }
        modeButtons[1].selected = true
        let modeBtnStack = NSStackView(views: modeButtons)
        modeBtnStack.orientation = .horizontal; modeBtnStack.spacing = 7; modeBtnStack.distribution = .fillEqually
        let modeRow = NSStackView(views: [modeLabel, modeBtnStack])
        modeRow.orientation = .horizontal; modeRow.spacing = 12; modeRow.alignment = .centerY
        controls.addArrangedSubview(modeRow); pFull(modeRow)

        minSlider = NSSlider(value: 35, minValue: 12, maxValue: 140, target: self, action: #selector(minChanged))
        maxSlider = NSSlider(value: 75, minValue: 12, maxValue: 140, target: self, action: #selector(maxChanged))
        typoSlider = NSSlider(value: 3, minValue: 0, maxValue: 12, target: self, action: #selector(settingsChanged))
        countdownSlider = NSSlider(value: 4, minValue: 2, maxValue: 10, target: self, action: #selector(settingsChanged))
        [minSlider, maxSlider, typoSlider, countdownSlider].forEach { $0?.trackFillColor = cBlue }
        speedValue = valueLabel("35–75 wpm"); typoValue = valueLabel("3%"); countdownValue = valueLabel("4 s")

        for (lbl, sl, vl) in [("Min speed", minSlider!, nil as NSTextField?), ("Max speed", maxSlider!, speedValue),
                              ("Mistakes", typoSlider!, typoValue), ("Start delay", countdownSlider!, countdownValue)] {
            let row = labeledRow(lbl, sl, vl); controls.addArrangedSubview(row); pFull(row)
        }

        let hint = NSTextField(labelWithString: "Speed drifts between min and max. “Max Human” widens that drift and adds more pauses.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = cMuted
        controls.addArrangedSubview(hint); pFull(hint)

        humanizeToggle = PillToggle(); humanizeToggle.isOn = true
        newlineToggle = PillToggle(); newlineToggle.isOn = true
        let t1 = toggleRow(humanizeToggle, "Human rhythm, pauses & typos")
        let t2 = toggleRow(newlineToggle, "Treat new lines as the Return key")
        controls.addArrangedSubview(t1); pFull(t1)
        controls.addArrangedSubview(t2); pFull(t2)

        // Start
        startButton = FancyButton("Start typing", kind: .primary)
        startButton.target = self; startButton.action = #selector(startTapped); startButton.keyEquivalent = "\r"
        stack.addArrangedSubview(startButton); full(startButton)
        startButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        progress = NSProgressIndicator()
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100; progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(progress); full(progress)

        statusLabel = NSTextField(wrappingLabelWithString: "Ready.")
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = cMuted
        stack.addArrangedSubview(statusLabel); full(statusLabel)

        window.makeKeyAndOrderFront(nil)
        syncLabels()
    }

    func valueLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right; l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium); l.textColor = cBlueBright
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.widthAnchor.constraint(equalToConstant: 86).isActive = true
        return l
    }
    func labeledRow(_ label: String, _ control: NSView, _ value: NSTextField?) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 13); name.textColor = cText
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.widthAnchor.constraint(equalToConstant: 88).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [name, control]
        if let v = value { views.append(v) } else { let p = NSView(); p.widthAnchor.constraint(equalToConstant: 86).isActive = true; views.append(p) }
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        return row
    }
    func toggleRow(_ toggle: PillToggle, _ label: String) -> NSView {
        toggle.target = self; toggle.action = #selector(settingsChanged)
        let name = NSTextField(labelWithString: label); name.font = .systemFont(ofSize: 13); name.textColor = cText
        let row = NSStackView(views: [toggle, name]); row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        return row
    }

    // MARK: settings + modes

    @objc func minChanged() { if minSlider.doubleValue > maxSlider.doubleValue { maxSlider.doubleValue = minSlider.doubleValue }; syncLabels() }
    @objc func maxChanged() { if maxSlider.doubleValue < minSlider.doubleValue { minSlider.doubleValue = maxSlider.doubleValue }; syncLabels() }
    @objc func settingsChanged() { syncLabels() }

    @objc func modeTapped(_ sender: FancyButton) { applyMode(sender.tag) }
    @objc func modeMenu(_ sender: NSMenuItem) { applyMode(sender.tag) }
    func applyMode(_ index: Int) {
        for b in modeButtons { b.selected = (b.tag == index) }
        switch index {
        case 0: // Steady — constant speed, no typos, no rhythm
            minSlider.doubleValue = 55; maxSlider.doubleValue = 55; typoSlider.doubleValue = 0
            humanizeToggle.isOn = false; maxHumanMode = false
            setStatus("Mode: Steady — constant speed, clean (no drift or typos).")
        case 2: // Max Human — widest drift, most pauses, most mistakes
            minSlider.doubleValue = 15; maxSlider.doubleValue = 110; typoSlider.doubleValue = 7
            humanizeToggle.isOn = true; maxHumanMode = true
            setStatus("Mode: Max Human — huge speed swings, re-reading pauses, false-start restarts, more typos.")
        default: // Natural
            minSlider.doubleValue = 35; maxSlider.doubleValue = 75; typoSlider.doubleValue = 3
            humanizeToggle.isOn = true; maxHumanMode = false
            setStatus("Mode: Natural — balanced human typing.")
        }
        syncLabels()
    }

    func syncLabels() {
        let mn = minSlider.doubleValue.rounded(), mx = maxSlider.doubleValue.rounded()
        speedValue.stringValue = "\(Int(mn))–\(Int(mx)) wpm"
        typoValue.stringValue = "\(Int(typoSlider.doubleValue.rounded()))%"
        countdownValue.stringValue = "\(Int(countdownSlider.doubleValue.rounded())) s"
        typoSlider.isEnabled = humanizeToggle.isOn
        engine.minWPM = mn; engine.maxWPM = mx
        engine.typoRate = typoSlider.doubleValue.rounded() / 100.0
        engine.humanize = humanizeToggle.isOn
        engine.newlineAsReturn = newlineToggle.isOn
        engine.maxHuman = maxHumanMode
    }

    // MARK: compact mode

    @objc func toggleCompact() {
        compact.toggle()
        subtitleLabel.isHidden = compact
        controlsPanel.isHidden = compact
        compactButton.title = compact ? "Expand" : "Compact"
        compactButton.invalidateIntrinsicContentSize(); compactButton.needsDisplay = true
        let target = compact ? compactSize : fullSize
        var f = window.frame
        let topY = f.maxY
        f.size = target
        f.origin.y = topY - target.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            window.animator().setFrame(f, display: true)
        }
    }

    // MARK: humanize

    @objc func humanizeTapped() {
        guard let ts = textView.textStorage else { textView.string = Humanizer.humanize(textView.string); return }
        let original = textView.string
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setStatus("Nothing to humanize — paste some text first."); return }
        let cleaned = Humanizer.humanize(original)
        let fullRange = NSRange(location: 0, length: ts.length)
        if textView.shouldChangeText(in: fullRange, replacementString: cleaned) {
            ts.replaceCharacters(in: fullRange, with: cleaned); textView.didChangeText()
        }
        let saved = max(0, original.count - cleaned.count)
        setStatus("Humanized — stripped AI tells. \(saved) characters trimmed. ⌘Z to undo.")
    }

    // MARK: start / countdown / type

    @objc func startTapped() {
        if state != .idle { return }
        if !AXIsProcessTrusted() { requestAccessibility(); return }
        beginCountdown()
    }
    func beginCountdown() {
        let text = textView.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { setStatus("Paste some text first."); return }
        syncLabels()
        state = .counting
        startButton.isEnabled = false; humanizeButton.isEnabled = false; textView.isEditable = false
        progress.doubleValue = 0; didHide = false
        remaining = Int(countdownSlider.doubleValue.rounded())
        setStatus("Click into your target field now — typing in \(remaining)…  (ESC to cancel)")
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { return }
            self.remaining -= 1
            if self.remaining > 0 { self.setStatus("Typing in \(self.remaining)…  (ESC to cancel)") }
            else { t.invalidate(); self.countdownTimer = nil; self.beginTyping(text) }
        }
    }
    func beginTyping(_ text: String) {
        state = .typing
        setStatus("Typing…  (ESC to stop)")
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { didHide = true; NSApp.hide(nil) }
        engine.onProgress = { [weak self] p in self?.progress.doubleValue = p * 100; self?.setStatus("Typing… \(Int(p * 100))%  (ESC to stop)") }
        engine.onStatus = { [weak self] s in self?.setStatus(s) }
        engine.onFinished = { [weak self] done in self?.finishTyping(completed: done) }
        engine.start(text: text)
    }
    func finishTyping(completed: Bool) {
        state = .idle
        startButton.isEnabled = true; humanizeButton.isEnabled = true; textView.isEditable = true
        if completed { progress.doubleValue = 100 }
        if didHide { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true); didHide = false }
        setStatus(completed ? "Done." : "Stopped.")
    }
    @objc func stopOrCancel() {
        switch state {
        case .counting:
            countdownTimer?.invalidate(); countdownTimer = nil
            state = .idle; startButton.isEnabled = true; humanizeButton.isEnabled = true; textView.isEditable = true
            setStatus("Cancelled.")
        case .typing: engine.stop()
        case .idle: break
        }
    }
    func setStatus(_ s: String) { statusLabel.stringValue = s }

    func installEscMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == kEscape { DispatchQueue.main.async { self?.stopOrCancel() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == kEscape { self?.stopOrCancel(); return nil }
            return e
        }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        startButton.isEnabled = false; startButton.title = "Waiting for permission…"; startButton.needsDisplay = true
        setStatus("Turn ON “DripWriter” in System Settings ▸ Privacy & Security ▸ Accessibility. I’ll detect it automatically — no need to restart.")
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                t.invalidate(); self.permissionTimer = nil
                self.startButton.title = "Start typing"; self.startButton.isEnabled = true; self.startButton.needsDisplay = true
                self.setStatus("Permission granted ✓ — press Start typing."); NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About DripWriter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DripWriter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DripWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let hz = editMenu.addItem(withTitle: "Humanize Text", action: #selector(humanizeTapped), keyEquivalent: "h")
        hz.keyEquivalentModifierMask = [.command, .shift]

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Toggle Compact", action: #selector(toggleCompact), keyEquivalent: "k")
        viewMenu.addItem(.separator())
        for (i, name) in ["Steady", "Natural", "Max Human"].enumerated() {
            let it = viewMenu.addItem(withTitle: "Mode: \(name)", action: #selector(modeMenu(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i
        }
        NSApp.mainMenu = main
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
