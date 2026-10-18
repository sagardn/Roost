# Working in this repository

Roost is a macOS menu bar app: an app launcher and window switcher, and a
system monitor. It is being made fully independent of the project it was
forked from, and that migration governs how new work is done.

It was called **Perch** until 1.0.19. The name still appears, deliberately,
where installed copies are met -- the `FormerName` migration, the `Perch.dmg`
bridge in `release.yaml`, the install scripts -- and `docs/ARCHITECTURE.md` ▸
The name lists them. Do not "finish the rename" there: removing the bridge
strands every installed Perch on its last version.

Read `docs/ARCHITECTURE.md` before changing anything structural. It records
which parts of the tree are independent, which are still derived, and how far
the migration has got.

## The one rule that matters

**`Roost/Monitor/` is the real codebase. `Kit/` and `Modules/` are gone.**

- Put new monitoring features in `Roost/Monitor/`. Finding and removing
  things -- large files, apps, command-line tools -- is not monitoring and
  lives in `Roost/Cleanup/`; see `docs/ARCHITECTURE.md` ▸ Cleanup for the
  four rules that area holds to.
- Never copy code out of the upstream project. Taking a file does not make it
  independent; it carries its authorship with it. Implement against the public
  macOS APIs instead — `host_statistics64`, `host_processor_info`,
  `getifaddrs`, `IOPowerSources`, the IORegistry, `sysctl` — and the
  documented behaviour of the feature.
- Never add a dependency on the upstream project: not as a submodule, a
  package, a service, a release feed, or a copied file.

## Conventions

- **Swift, AppKit, no third-party packages.** The only dependency is
  `LaunchAtLogin`. Keep it that way; a dependency is a thing to maintain.
- **Comments say why, not what.** The codebase explains decisions —
  measurements, rejected alternatives, API constraints. Match that. A comment
  restating the line below it is noise; one recording why the obvious approach
  failed is the most valuable thing in the file.
- **Measure, don't guess.** Colours are validated, not picked. Widths are
  measured against the strings they must hold. Timings are timed. If a claim
  can be checked, check it before writing it down.
- **Naming collides.** `Kit` already defines `SystemStats`, `MenuBar`,
  `ChartView`, `NetworkChartView` and `PopupWindow`. Independent equivalents
  use their own names (`Readings`, `ReadingPopup`); grep before naming a type.

## Tests

```bash
Tools/run-tests.sh            # all of them, about 25 seconds
Tools/run-tests.sh disk       # just Tools/disk-test.swift
```

Thirty-seven suites, 1,619 assertions. `tests.yaml` runs the same script on every
push, so a suite that fails fails the build.

Pure logic gets a test. The pattern is a script compiled against the app's
own source, so it cannot drift from what ships:

```bash
cat Roost/Launcher/Gesture.swift Tools/gesture-test.swift | swift -
```

A suite is `cat`ed together with everything it reads, so the list grows as a
suite does — add a file to the suite and the command stops compiling until
you add it to the command too. That command lives in the suite's own `Run:`
header, and `run-tests.sh` reads it from there rather than keeping a second
copy: a second list is a list that drifts, and the way it drifts is that a
suite silently stops being run.

Add to them when you add a reader — parsers and band boundaries are cheap to
test and have already caught real bugs here.

**Give the type checker the types in a suite's fixtures.** A fixture is
usually a literal with nested `.init`s and a `map` or two, which is exactly
the shape Swift's inference is slowest on. `widget-test` had one that took
1137ms here and *failed to compile at all* on a CI runner, which is slower --
and so the whole tests workflow was red from the day it was added. Declare
the type on the local, and lift a `map` or a repeated call out of the
expression. To find the next one:

```bash
swiftc -typecheck -Xfrontend -warn-long-expression-type-checking=150 <file>
```

A suite must do two things, and the runner checks both: print `all passed` or
`<n> failed` as its last line, and exit non-zero when an assertion failed.
The exit status alone cannot tell a failed assertion from a suite that never
reached its assertions — a compile error, an OOM kill and a trap inside a live
IOKit call all exit non-zero with nothing disproved. A suite that exits
non-zero without the marker is reported as **did not run to completion**, with
its exit status, rather than as a failure. The distinction matters because
"failed" sends the next person looking for a bug in the code under test.

Two things that are deliberately not tests:

- `Tools/windows-probe.swift` asserts nothing. It prints the live window list
  and needs Accessibility permission. It was called `windows-test.swift`,
  which meant the runner counted it as a suite that passed while it checked
  nothing at all.
- `xcodebuild test` does not work and should not. The Tests target had no
  sources in it and printed **TEST SUCCEEDED** for zero tests; it is gone, so
  the scheme now says it is not configured for testing instead of answering
  green.

## Localisation

```bash
python3 Tools/i18n.py        # the 41 .lproj files are in step with en.lproj
python3 Tools/i18n.py scan   # en.lproj is in step with the code
```

Both run in CI, and `scan` is the one that will catch you. Write a new
`localized("…")` and it fails until the key is in
`Roost/Supporting Files/en.lproj/Localizable.strings`; `python3 Tools/i18n.py
fix` then carries it into the other 40. Rename a localised string and the old
key becomes unused, which fails the same way — rename it in en.lproj in the
same commit.

Reading a key out of a variable is fine as long as the value exists as a
literal somewhere, which is how `scan` sees it. A key *computed* at runtime is
invisible to it and makes its unused list untrustworthy; `docs/ARCHITECTURE.md`
▸ Localisation lists the call sites that pass a variable today.

## Building and releasing

```bash
# build without signing
xcodebuild -project Roost.xcodeproj -scheme Roost -configuration Release \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Releases are tag-driven: bump `MARKETING_VERSION` in the project **and**
`CFBundleVersion` in `Roost/Supporting Files/Info.plist`, commit, then tag
`vX.Y.Z`. CI fails the build if the tag and `MARKETING_VERSION` disagree.

Releases are **ad-hoc signed**, so every release build changes its code hash
and macOS drops its Accessibility grant. Local installs avoid that: install
with `Tools/install-local.sh`, which signs with the self-signed "Roost Dev"
identity in the login keychain, so the grant survives every rebuild. The
plain `xcodebuild` above produces an *unsigned* app; installing that one
revokes the grant, and is not a regression in the hotkeys.

## Licensing

Roost is MIT, © 2026 Sagar, and nothing in the tree is anyone else's: the
last derived content -- the translations, `Tools/i18n.py`, the `Makefile`
and a handful of assets -- was replaced or deleted when it was relicensed.
`docs/ARCHITECTURE.md` records how that was audited.

- Never bring back a file from before the relicensing. That history carries
  upstream's work under upstream's notice, and restoring it restores the
  obligation.
- Never add third-party code, translations or images without its licence, and
  if its licence asks for a notice, the notice goes in before the code does.
- Translations are written from `en.lproj`, never from an older translation.
- Never claim authorship of a file you did not write.
