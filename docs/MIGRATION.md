# Migration checklist

Replacing the derived code with independent implementations. Measured
from the source, not estimated. Update it as modules land.

**Rule:** implement → verify → remove the original → verify again. Nothing is
deleted before its replacement works.

---

## The whole feature surface

What `Kit/` + `Modules/` provided, counted from the code at the time. Both
directories are gone; the table is kept as the record of what had to be
replaced.

| Surface | Count | Independent | Note |
|---|---:|---:|---|
| Modules | 9 | 3 started, **1 at parity** | CPU is the only complete one |
| Menu bar widget types | 14 | 2 | `MenuBarWidget` covers `mini` and `speed` |
| Module settings rows | 52 | 0 | no independent settings layer exists |
| App settings rows | 27 | 0 | Settings window is Kit's |
| Notification options | 21 | 0 | not started |
| Localizations | 41 | 0 | English only on the native side |
| WidgetKit extension | 1 | 0 | decodes module types directly |
| SMC / fan control | 869 lines | 0 | legacy, unmaintained upstream |

Lines: **41,104 derived** against **3,093 independent** in `Roost/Monitor/`.

---

## Per module

Widget types are the menu bar shapes each module offers. Settings and
notifications are option counts from `settings.swift` / `notifications.swift`.

| Module | Lines | Widgets | Settings | Notifs | Reader | Popup | Menu bar | Settings | Notifs | Deletable |
|---|---:|---|---:|---:|:-:|:-:|:-:|:-:|:-:|:-:|
| **CPU** | 2,741 | bar_chart, label, line_chart, mini, pie_chart, tachometer | 7 | 6 | ✅ | ✅ | ✅ | ❌ | ❌ | blocked |
| RAM | 1,853 | + memory, state, text | 6 | 4 | ✅ | partial | ✅ | ❌ | ❌ | no |
| Net | 3,963 | label, network_chart, speed, state, text | 14 | 5 | ✅ | partial | ✅ | ❌ | ❌ | no |
| GPU | 1,482 | bar_chart, label, line_chart, mini, tachometer, text | 3 | 1 | ✅ | ❌ | ❌ | ❌ | ❌ | no |
| Disk | 3,374 | bar_chart, label, memory, mini, network_chart, pie_chart, speed, text | 10 | 1 | partial | ❌ | ❌ | ❌ | ❌ | no |
| Battery | 1,287 | bar_chart, battery, battery_details, label, mini | 2 | 2 | partial | ❌ | ❌ | ❌ | ❌ | no |
| Sensors | 3,115 | bar_chart, label, mini, sensors | 8 | 1 | partial | ❌ | ❌ | ❌ | ❌ | no |
| Bluetooth | 1,037 | label, sensors | 1 | 1 | ❌ | ❌ | ❌ | ❌ | ❌ | no |
| Clock | 1,780 | label, sensors | 1 | 0 | ❌ | ❌ | ❌ | ❌ | ❌ | no |
| ~~Remote~~ | ~~1,579~~ | — | — | — | — | — | — | — | — | ✅ **deleted** |

"partial" reader means `Readings.swift` or `Temperature.swift` covers the
headline number but not the module's full detail.

---

## What blocks deletion

A module cannot be deleted until nothing else needs it. Three shared things
block all nine:

1. **Settings layer.** `Kit`'s `Store` backs all 79 settings rows and every
   user preference already on disk. No module can lose its Kit half until an
   independent settings layer exists that reads the same keys — otherwise
   every user's configuration resets.
2. **WidgetKit extension.** `Widgets/UnitedWidget.swift` decodes module types
   (`CPU_Load` and friends) straight out of `Modules/`. Deleting a module
   compiles fine and silently breaks the desktop widgets.
3. **Module system.** `Kit/module/` is the lifecycle every module hangs off —
   enable/disable, readers, popup registration, the menu bar item.

Doing these three once unblocks all nine modules. Doing another module first
unblocks nothing.

---

## Order of work

1. ~~Remote service~~ — **done**, 3,414 lines deleted, no feature lost.
2. ~~Popup kit~~ — **done** (`Popup`, `PopupSection`, `Modules`).
3. ~~Menu bar widget layer~~ — **done** (`MenuBarWidget`), covers `mini` and `speed`.
4. ~~CPU to parity~~ — **done**, all eight popup sections.
5. ~~Settings layer~~ — **done** (`Preferences`), reading the same keys, so
   no preference was lost.
6. ~~WidgetKit feed~~ — **dropped with the extension**, which an ad-hoc
   signed build could not run.
7. ~~Modules one at a time~~ — **done**: CPU, RAM, Network, GPU, Disk,
   Sensors. Battery and Bluetooth were dropped as features rather than
   rebuilt, because macOS already shows both.
8. ~~Remaining widget types~~ — **done**, nine shapes in `MenuBarWidget`.
9. ~~Sensors, Bluetooth, Clock~~ — Sensors rebuilt; the other two dropped.
10. ~~Localizations~~ — kept, all 41 languages, and that is a thinner
    claim than it sounds: the files are in step and machine-translated, and
    the rebuilt popups mostly do not call `localized()` at all. See
    `docs/ARCHITECTURE.md` ▸ Localisation.
11. ~~Delete `Kit/`~~ — **done**, along with its Xcode target.

The attribution did not come out with `Kit/`: four shell files, the login
item helper, the translations, two scripts and some assets were still
derived, and the notice stayed until the last of them was rewritten or
deleted. It has been, and Roost is now MIT under its own copyright alone --
see `docs/ARCHITECTURE.md`.

---

## Scope decision outstanding

The honest cost is driven by breadth, not difficulty. Three levers:

- **Sensors** (3,115 lines + 869 of SMC) is the hardest to reimplement —
  per-model SMC key tables and fan control that upstream already calls legacy
  and unmaintained. Dropping it removes the single worst item.
- **41 localizations.** Shipping English only removes a large, permanent
  maintenance surface.
- **14 widget types.** Most modules use three or four; the long tail
  (`tachometer`, `pie_chart`, `state`, `memory`) may not be worth rebuilding.

Deciding what *not* to keep is the fastest way to finish. Nothing here is
technically blocked — it is all volume.
