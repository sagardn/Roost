# Performance baseline

Reproduce with `./Tools/bench.sh`. **Do not claim an improvement without
re-running it on the same machine with the same modules enabled** — these
numbers are a reference point for one configuration, not an absolute.

## Re-measured 2026-10-17 — the idle cost of warming the window-state cache

Same machine (MacBook Air 13", M2, 16 GB), macOS 27.0. Modules on: CPU, GPU,
RAM, Disk, Network, Clipboard. Sensors off. Nine regular apps running, no
Roost window open, nothing being typed.

| Measure | before | after |
|---|---|---|
| Idle CPU, 2 s samples | mean 5.5 %, peak **17.7 %** (8 samples) | mean **1.53 %**, peak 2.3 % (15 samples) |

The app was doing nothing visible in either case. The cost was
`Launcher`'s warm timer calling `WindowControl.warmStaleStates()` every two
seconds: three apps per fire, each one blocking Accessibility IPC into that
app, about 78 ms of main-thread IPC every two seconds for ever. It also woke
every app it read, so the heat was not confined to Roost -- which is how it
was noticed, as a warm laptop rather than as a slow app.

It could not do its job either, which is what settles it. Three apps every
two seconds is 1.5 a second; nine apps on the five-second life the cache then
had need 1.8 a second to stay fresh. It never caught up, so the search panel
paid the full sweep on opening anyway. The cost was real and the benefit was
arithmetically unreachable, and both got worse the more apps were open.

What replaced it: the timer and `warmStaleStates` are gone, the cache lives
60 s instead of 5, and the `NSWorkspace` notifications for hiding, unhiding,
launching and quitting invalidate the entry for that app (activation was
already covered by `Recents`). Nothing sweeps on a clock. A stale entry can
only affect the state drawn in a search row, never what a click does, because
`WindowControl.toggle` reads the windows fresh every time and never consults
the cache.

Also measured, and left alone deliberately: copying a 181 MB TIFF takes the
resident set from 111 MB to 435 MB, because `ClipboardCapture.read` fetches
the whole image and *then* rejects it for being over the 25 MB limit. It is a
spike, not a leak -- three copies in a row stayed at 435 MB and it drains
back toward baseline -- but it lands on a machine already at 70 % memory.

The check cannot come first. A pasteboard hands over a type's bytes or
nothing and has no way of being asked how many there are. An `autoreleasepool`
around the read was tried and measured 428 MB against 435, which is noise:
the read runs in a `Timer` callback and the run loop already drains a pool
around each one, so there was nothing for a second pool to release. The code
went back to the simple version with the finding written down in it.

What actually bounds this is the order the types are tried in. PNG and JPEG
come before TIFF, so a screenshot is captured as PNG at a few MB and its
181 MB TIFF form is never asked for. The figure above is a synthetic
worst case, not what copying a screenshot costs.

Two more things measured the same day and *not* changed, both for the same
reason -- the measurement said the change was not worth its risk:

| Considered | Measured | Why it was dropped |
|---|---|---|
| Move `ClipboardCapture.read` and its SHA256 off the main thread | SHA256 is 2.1 ms at 5 MB, 10.7 ms at 25 MB (the largest image the limit accepts), 77.8 ms at 181 MB (never reached -- oversize returns before hashing) | 10.7 ms is inside one frame. A background read is also a race: `NSPasteboard` has no snapshot, so a read that lands after a second copy returns the new bytes under the old change count, and the only guard is discarding the capture -- a clipboard manager that loses entries when you copy twice quickly |
| Make the Dashboard's card fill opaque | card 1.04:1 against the window, settings card 1.49:1 | The right fix was not opacity. The two fills are meant to be identical and differ tenfold, because `withAlphaComponent(0.14)` sets the alpha where SwiftUI's `.opacity(0.14)` multiplies the colour's own 0.1. `Surface` now sets it, and matches |

## Re-measured 2026-10-15 — Roost 1.0.16

Same machine (MacBook Air 13", M2, 16 GB), macOS 27.0 (26A428). Modules on:
CPU, GPU, RAM, Disk, Network. Sensors off. Menu bar items separate, not
combined.

| Measure | 2026-10-09, 1.0.11 | 2026-10-15, 1.0.16 |
|---|---|---|
| Idle CPU, sustained | 6.0 % | **2.84 %, 2.71 %, 2.90 %** across 3 × 45–60 s |
| Resident, fresh process | 127 MB | **68 MB**, flat over 5 min (68.1 → 68.7) |
| Resident, after opening windows | — | 101–128 MB, and it comes back down |

Two cautions on reading that table. The configurations are not identical --
Disk is on now and was off then -- so this is not a clean before-and-after of
any single change. And the idle figure moves by a few tenths between windows
on an otherwise idle machine, which is why three are quoted: a single window
is not evidence, and a 31 % "win" measured here from one window turned out to
be noise.

The reader poll interval row cited `Kit/module/reader.swift:57`. That file has
not existed since `Kit/` was deleted. The 1-second tick is
`MonitorBar.startTicking`, `Roost/Monitor/MonitorBar.swift:369`.

### Costs worth knowing, measured the same day

| What | Cost | Where it matters |
|---|---|---|
| `DiskModule.isAvailable` | 6.16 ms | was read every tick in combined mode; now cached |
| `GPUModule.isAvailable` | 1.58 ms | same; now answered once |
| `DiskReadings.volumes()` | 6.16 ms | every 15 ticks, popup only |
| `DiskReadings.counters()` | 0.07 ms | every tick |
| Reading the Dock over Accessibility | **59.95 ms** first, **2.21 ms** after | the first is the AX connection warming up, paid at launch off the main thread |
| `CGWindowList` on-screen check | 0.68 ms | one Dock click |
| `AIAssistants.find()` | 0.10 s for 2.7 GB | only walks what it offers |
| Full test suite | 25.7 s, 32 suites | before every release |

## The original run — 2026-10-09, Roost 1.0.11

Measured on the same MacBook Air 13" (M2, 8 cores, 16 GB), macOS 27.0, installed
at `/Applications/Roost.app`, ad-hoc signed. Modules on: CPU, GPU, RAM, Network.
Off: Disk, Sensors, Battery, Bluetooth. No popup or settings window was opened.

Kept rather than replaced, because its method notes -- particularly the
`ps -o %cpu` trap below -- are the reason the newer numbers are taken the way
they are.

| Measure | Result | Confidence |
|---|---|---|
| Idle CPU, sustained | **6.0 %** (5.66–6.19 % across 6 × 15 s) | high — very stable |
| Resident memory, settled | **127 MB** | high |
| Resident memory, peak at launch | 219 MB | high |
| Reader poll interval | **1 s**, every reader | exact (`Kit/module/reader.swift:57`) |
| Cold start to first menu bar item | 7.5 s / 43.5 s / 19.3 s | **low — see below** |

6 % sustained is the headline. For a menu bar monitor that is doing nothing
visible, on a machine doing nothing else, that is a lot: it is roughly half a
core-percent per enabled module per second of wall clock, and it is paid
whether or not anybody is looking.

### Why the startup number is not usable yet

The three cold-start runs disagree by a factor of six. The app is ad-hoc signed
and unnotarised, so Gatekeeper re-assesses the bundle on launch, and the bundle
had just been replaced — that is almost certainly what the 43 s run measured,
not Roost. A usable figure needs the same bundle launched repeatedly with no
reinstall in between, and ideally the app's own `"Roost started in …"` line
rather than polling for a menu bar window. **Treat startup as unmeasured.**

### A measurement trap worth recording

`ps -o %cpu` is the **average since the process started**, not current usage.
Sampling it 60 times on a freshly launched app reported *8.0 % mean, 23.4 %
max* — a decaying startup transient, read as if it were steady-state noise.
The true sustained figure, from the delta in cumulative CPU time, is 6.0 % with
a spread of half a percent. `Tools/bench.sh` does it the second way.

## Where the time actually goes

From `sample` over 15 s at idle (`/tmp/roost.sample.txt`). This is a sampling
profiler, not Instruments — directional, good enough to pick a target, not
precise attribution.

The heaviest frames are **not data collection**:

```
   42  AppKit           NSPerformVisuallyAtomicChange
   24  CoreAutoLayout   -[NSISEngine withBehaviors:performModifications:]
   24  UIFoundation     __NSStringDrawingEngine
   23  CoreAutoLayout   -[NSLayoutConstraint _addToEngine:…]
   22  CoreSVG          EnumerateNode(SVGNode const*, …)
   23  libswiftCore     swift_release_dealloc
   33  libsystem_malloc _xzm_xzone_malloc_tiny
   21  AppKit           -[NSView … _populateEngineWithConstraints…]
```

Reading that list: constraints being added to the layout engine, strings being
measured and drawn, SVG nodes being walked, and objects being allocated and
released — once per tick, forever. No `host_processor_info`, no `sysctl`, no
IOKit. **The cost is in redrawing the menu bar, not in reading the hardware.**

One Auto Layout path appears on a chart's own background queue
(`com.sagar.roost.Charts.Line`), which is worth a second look on its own
merits: AppKit layout off the main thread is not safe regardless of its cost.

## What this means for the rebuild

The independent layer in `Roost/Monitor/` currently replaces **readers** —
`CPUReadings`, `MemoryReadings`, `NetworkMonitor`, `GPUStats`, `Temperature`.
The profile says readers are not where the 6 % is. Rewriting them is still
worth doing for independence from the inherited architecture, but **it should not
be expected to move this number**, and a rewrite that reproduces the same
per-tick view rebuilding will land in exactly the same place.

Ranked by measured cost against likely effort:

1. **Stop rebuilding menu bar widget views every tick.** Update the value and
   redraw; do not re-add constraints, re-measure strings, or re-rasterise an
   SVG each second. This is where the samples are.
2. **Do not pay for what nobody is looking at.** `Charts.displayIfVisible()`
   already guards redraws on window visibility; the same discipline needs to
   reach the widgets and the popup content.
3. **Reconsider the flat 1 s interval.** Every reader ticks once a second
   regardless of whether its value is on screen or changing. Adaptive or
   event-driven intervals are the obvious follow-up — but only after 1 and 2,
   because halving the tick rate of cheap work saves nothing.

Numbers 1 and 2 are rendering work in `Kit/Widgets/` and `Kit/module/`, which
is derived code the rebuild intends to replace anyway. Doing them as part
of the replacement, rather than as a patch to code that is on its way out, is
the cheaper order.
