# Contributing to Roost

Pull requests are welcome. This file is the short version of what makes them
easy to merge.

## Build it

Roost needs **Xcode** and **macOS 14 or newer**.

```bash
git clone https://github.com/sagardn/Roost.git
cd Roost
xcodebuild -project Roost.xcodeproj -scheme Roost -configuration Debug build
```

If `xcodebuild` reports the wrong developer directory, Xcode is installed but not
selected:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

The app calls `NSGlassEffectView`, which exists only in the **macOS 26 SDK**, so
an older Xcode fails at compile time rather than degrading at runtime. CI builds
on `macos-26` for the same reason.

switcher code with the main app.

## How the project is laid out

| Path | What lives there |
| --- | --- |
| `Kit/` | shared framework: charts, widgets, popup and window plumbing, `Store`, the colour palette in `Kit/constants.swift` |
| `Modules/<Name>/` | one folder per metric — reader, popup, portal, widget, settings |
| `Roost/` | the app itself: `AppDelegate`, the settings window, and `Roost/Launcher/` (search panel, hotkeys, window control) |
| `Widgets/` | the macOS widget extension |

A metric is usually drawn in four places — the menu bar widget, the popup, the
dashboard portal and the module's settings page. Changing a colour or a marker
in one of them does not change the others; check all four.

## Things worth knowing before you change them

- **Colours are validated, not chosen.** The series, load and breakdown palettes
  were measured for lightness, chroma and colour-blind separation on both light
  and dark surfaces. If you change one, keep a magnitude ramp to a single hue,
  keep status colours out of series slots, and keep adjacent pairs apart. The
  reasoning is in the comments next to each definition.
- **SwiftLint runs on every push.** Match the surrounding style. If a rule
  genuinely hurts readability, scope a `swiftlint:disable` to the smallest range
  and write down why.
- **`Branding` in `Kit/constants.swift`** holds every outward link — repository,
  issues, releases, donations, the update feed. Nothing should hardcode a URL
  around it.
- **The updater replaces the running app.** `Silent` downloads and installs
  without asking, which is why it is not the default. Be careful there.

## Pull requests

- One change per PR; two unrelated fixes are two PRs.
- Describe what it does and **why** — the why is what a reviewer cannot get from
  the diff.
- Say which Mac and macOS version you tested on. Sensor keys and temperatures
  differ across generations, and a lot of this code cannot be tested on one
  machine.
- Screenshots for anything visual, before and after.

Open a large change as an issue first so two people do not build the same thing
twice. Small fixes need no discussion — just send them.

## Translations

Every string lives in `Roost/Supporting Files/<lang>.lproj/Localizable.strings`.
To add a language, copy `en.lproj/Localizable.strings`, translate the values on
the right of each `=`, and leave the keys untouched — a changed key silently
falls back to English. The `i18n check` workflow verifies that every file has the
same keys.

## Credit

Roost is MIT, © 2026 Sagar, and contributions are accepted under the same
licence. Please contribute only work you have the right to give: no code,
translations or images copied from other projects.
