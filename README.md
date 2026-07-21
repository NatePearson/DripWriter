<div align="center">

<img src="docs/hero.svg" alt="DripWriter" width="820">

# DripWriter

**Human, variable-speed auto-typing for macOS.**
Paste text, click any field, and it types like a person: drifting speed, pauses, fatigue, and typos it fixes.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-0b1830?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-3B82F6?logo=swift&logoColor=white)](https://swift.org)
[![AppKit](https://img.shields.io/badge/UI-AppKit-1D4ED8)](#)
[![No deps](https://img.shields.io/badge/dependencies-none-22c55e)](#)
[![License: MIT](https://img.shields.io/badge/license-MIT-60A5FA)](LICENSE)
[![Download](https://img.shields.io/github/v/release/NatePearson/DripWriter?color=3B82F6&label=download&logo=apple&logoColor=white)](https://github.com/NatePearson/DripWriter/releases/latest)

### ⬇ [**Download for macOS**](https://github.com/NatePearson/DripWriter/releases/latest/download/DripWriter.zip)  ·  [**Landing page**](https://natepearson.github.io/DripWriter/)

</div>

---

## What it is

DripWriter "drips" text into whatever field you pick: a LinkedIn box, a doc, an email, a form. It
types the way people actually type. The pace **wanders** between a min and max instead of holding one
robotic rate, it pauses at punctuation, slows down as it "tires," and every so often makes a typo and
fixes it. A built-in **Humanize** pass strips common AI writing tells before you send.

One native AppKit app. No Python, no runtime, no dependencies.

## Features

- **Variable-WPM engine.** Speed is a random walk between your Min/Max sliders, with mean-reversion
  and the odd burst. Inconsistent on purpose; that's what reads as human.
- **Self-correcting typos.** Adjacent-key slips, doubled letters, transpositions, and
  "noticed-three-letters-later" corrections, all with believable backspacing.
- **Draft, then revise.** Instead of typing perfectly top to bottom, it leaves small imperfections in
  the draft (a lowercase sentence-start, a mistyped word, a dropped comma), then arrows back to each
  one, fixes it, and returns to the end, the way a person re-reads. The final text still matches your
  input exactly.
- **Three modes.** Steady (constant, clean), Natural (balanced), Max Human (the works).
- **✨ Humanize button.** An offline, rule-based port of the deterministic half of
  [blader/humanizer](https://github.com/blader/humanizer): dashes to commas, filler and hedging cuts,
  copula fixes, AI-vocab swaps, chatbot-artifact removal, curly-quote/emoji/bold cleanup.
- **Compact mode.** Collapse to a tiny typer that stays out of the way.
- **Keyboard shortcuts**, a blue/black OLED-dark UI, and **ESC** to stop instantly.

## Modes

| Mode | Speed range | Mistakes | Feel |
|------|-------------|----------|------|
| **Steady** | constant | 0% | Clean and robotic. No drift or typos |
| **Natural** | 35–75 wpm | 3% | Balanced everyday human typing |
| **Max Human** | 15–110 wpm | 7% | Big speed swings plus **draft-then-revise**: re-reads, arrows back to fix typos, capitalization, and punctuation, with planning pauses |

## How it types like a human

This is grounded in keystroke-logging writing research. Real typing comes in **bursts** separated by
pauses. The longest pauses (often **2 s+**) land at sentence boundaries, where people stop to plan;
shorter, more frequent ones show up during revision. Gaps under ~200 ms are motor, not thinking.

So the engine does more than vary speed. In **Max Human / draft-then-revise** it writes a rough draft,
then goes back to edit. Here's a real keystroke trace from the planner (`→`/`←` = cursor, `⌫` = delete,
`·` = pause):

```
The cat sat on yhe mat, and it was happy. the end.·[←×5]·⌫⌫⌫The·[←×27]·⌫⌫⌫the·[→×32]
  → "The cat sat on the mat, and it was happy. The end."
```

It typed "yhe" for "the" and left "the end" lowercase in the draft. Then it re-read, went back to
each spot, **deleted the whole word and retyped it** ("The", then "the"), and returned to the end.
The final text always equals your input. I checked that across 7,200 randomized runs.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘1` / `⌘2` / `⌘3` | Steady / Natural / Max Human |
| `⌘K` | Toggle Compact / Expand |
| `⌘⇧H` | Humanize the text |
| `⌘Z` | Undo (including a Humanize pass) |
| `ESC` | Stop typing |

## Download (prebuilt)

Grab the latest **[DripWriter.zip](https://github.com/NatePearson/DripWriter/releases/latest/download/DripWriter.zip)**,
unzip it, and move **DripWriter.app** to Applications. It needs **macOS 13+** and runs universal (Intel and Apple Silicon).

It's open-source and not notarized by Apple, so the first launch takes one step: **right-click → Open → Open**
(or System Settings → Privacy & Security → **Open Anyway**, or
`xattr -dr com.apple.quarantine /Applications/DripWriter.app`). Then grant Accessibility when prompted.

## Install & build (from source)

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/NatePearson/DripWriter.git
cd DripWriter
./build.sh          # compiles Sources/*.swift, assembles + ad-hoc-signs DripWriter.app
open DripWriter.app
```

### Grant Accessibility (one time)
DripWriter sends keystrokes to other apps, so macOS requires Accessibility permission.

1. Press **Start typing** once. It opens the right settings pane for you.
2. **System Settings → Privacy & Security → Accessibility → switch DripWriter ON**.
3. It **auto-detects** the grant, so there's no restart and no repeated prompts.

> Rebuilding changes the ad-hoc signature, so you may need to re-enable it.
> Clear a stale entry with `tccutil reset Accessibility com.natep.dripwriter`.

## How the Humanize pass works

It does only the **deterministic** fixes that are safe without changing meaning:

- em/en dashes → commas (number ranges kept as hyphens)
- filler ("in order to" → "to", "it is important to note that" → cut)
- hedging ("could potentially possibly" → "may")
- copula-avoidance ("serves as" → "is", "boasts a" → "has a")
- overused AI words ("utilize"/"leverage" → "use", "delve into" → "examine")
- signposting & chatbot artifacts ("Let's dive in", "I hope this helps!") → cut
- curly quotes → straight, emojis removed, **bold** markdown unwrapped, sentences re-capitalized

It does **not** attempt semantic rewrites (significance inflation, vague attributions, rule-of-three,
and the like). Those need a real LLM. Use it as a fast first pass, then read it over.

## Good to know

- **Won't work in password fields** or some hardened apps, which reject synthetic keystrokes by
  design. Normal text fields, browsers, docs, and chat boxes are fine.
- If you run **Grammarly Desktop**, it may try to "correct" the deliberate typos in your target field.
  Pause it while drip-typing if the output looks off.

## Project layout

```
Sources/main.swift       UI + variable-WPM typing engine + custom AppKit views
Sources/Planner.swift    keystroke planner (draft + revise), independently testable
Sources/Humanizer.swift  the Humanize ruleset
build.sh                 compile + bundle + ad-hoc sign
docs/                    GitHub Pages landing page
```

## Credits

- Humanize ruleset ported from [blader/humanizer](https://github.com/blader/humanizer).
- Built for typing demos, screen recordings, form testing, and natural-looking text entry.

## License

[MIT](LICENSE) © 2026 Nate Pearson
