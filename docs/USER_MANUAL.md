# Roost — User Manual

> Roost was called **Perch** until version 1.0.19. Perch does not update itself
> to Roost: install Roost with the command in the README, which removes Perch.
> On its first launch Roost brings your settings, launcher list and clipboard
> history across. Two things do not come across, because macOS
> keeps them by app identity: the Accessibility permission (allow Roost in
> System Settings ▸ Privacy & Security ▸ Accessibility) and Start at login
> (turn it on again in Settings).

Roost is two apps sharing one process:

- **a launcher and switcher** — a ⌃Space search panel, per-app hotkeys, your
  own ⌃Tab cycle, a minimise/restore key and a trackpad gesture.
- **a system monitor** — CPU, GPU, memory, disk, network and sensor readings
  drawn in the menu bar, each with a popup of detail behind it.

The two halves know nothing about each other, so you can use either one and
ignore the other: switch every module off and Roost is a launcher; ignore the
hotkeys and it is a system monitor.

---

## Contents

- [First run](#first-run)
- [Keyboard shortcuts](#keyboard-shortcuts) — the complete list
- [The search panel](#the-search-panel)
- [Managing your app list](#managing-your-app-list)
- [The trackpad gesture](#the-trackpad-gesture)
- [The system monitor](#the-system-monitor)
- [Clipboard history](#clipboard-history)
- [Settings](#settings)
- [Where Roost keeps things](#where-roost-keeps-things)
- [Privacy](#privacy)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)

---

## First run

Roost has no Dock icon by default — it lives in the menu bar. If no module has
anything to show in the menu bar, the Settings window opens by itself at launch
so there is something to click.

### Permissions

| Permission | What needs it | Where to grant it |
|---|---|---|
| **Accessibility** | Minimising, restoring and raising a specific window, and **New Window**. *Bringing an app forward* needs no permission, so the launcher partly works without it. | System Settings → Privacy & Security → Accessibility, or **Settings → Search & switcher → Window control → Allow…** |
| **Input Monitoring** | Module popup shortcuts only, and only once you set one. | System Settings → Privacy & Security → Input Monitoring |
| **Menu Bar** (macOS 26 and newer) | Showing any menu bar item at all. | System Settings → Menu Bar → turn Roost **on** |

Roost does not ask for anything at launch. It checks quietly, and asks for
Accessibility only when you do something that needs it. The global hotkeys are
registered through Carbon rather than an event tap, so **they work before
Accessibility is granted** — you get a notice instead of silence.

The trackpad gesture needs no permission at all; see
[The trackpad gesture](#the-trackpad-gesture).

> **Updating can make Accessibility look granted when it is not.** macOS ties
> the grant to the app's code signature, and Roost's ad-hoc signature changes
> with every build. If window control stops working after an update, select
> Roost in the Accessibility list, click **−**, then grant it again.

---

## Keyboard shortcuts

### Global — the launcher

These work from any app.

| Shortcut | Action |
|---|---|
| **⌃Space** | Open / close the search panel |
| **⌃`** | Minimise the frontmost window. Press again to bring back the last window you put away. |
| **⌃Tab** | Cycle the apps you marked for it, most recently used first. With nothing marked, it cycles recent apps. On by default — [it can be turned off](#search--switcher). |
| **⌃1** … **⌃9**, **⌃0** | Jump straight to the app holding that shortcut — no panel, no menu |

A per-app shortcut is a single character pressed with Control. The characters
Roost accepts are `0`–`9`, `` ` ``, `;` and `space`; anything else is ignored.

> **Careful with `` ` ``, `;` and `space`.** ⌃Space and ⌃` are already the panel
> and the minimise key. macOS gives a hotkey to whoever registers it first, so
> assigning one of those to an app means one of the two silently loses.

**⌃Tab is a global hotkey**, so while Roost holds it, browsers and terminals
lose it for tab switching. If another app registered ⌃Tab first, Roost notices,
moves its cycle to **⌥Tab** and says so at launch. To give ⌃Tab back entirely,
switch the cycle off in [Settings → Search & switcher](#search--switcher).

### Window snapping

Moves the frontmost window. Needs Accessibility, like minimising does.

| Shortcut | Puts the window |
|---|---|
| **⌃⌥←** / **⌃⌥→** | In the left / right half. Press again for two thirds, again for one third, again for half. |
| **⌃⌥↑** / **⌃⌥↓** | In the top / bottom half, cycling the same way |
| **⌃⌥U** **⌃⌥I** **⌃⌥J** **⌃⌥K** | In the top-left, top-right, bottom-left, bottom-right quarter |
| **⌃⌥↩** | Over the whole usable screen (not full screen: the menu bar and Dock stay) |
| **⌃⌥C** | In the centre, at its current size |
| **⌃⌥⌫** | Back where it was before Roost first moved it |
| **⌃⌥⌘←** / **⌃⌥⌘→** | On the previous / next display, at the same place and proportion |

These are Rectangle's keys. If Rectangle (or another window manager) is
running, it owns them, and Roost says which it could not claim. To give them
all back:

```bash
defaults write com.sagar.roost windowSnapping -bool false
```

then restart Roost.

### What a shortcut or a ↩ actually does

Activating an app is a *toggle*, so the same key both goes to an app and puts it
away:

| The app is… | What happens |
|---|---|
| not running | it launches (a notice says so if it is not installed) |
| hidden | it unhides and comes forward |
| minimised | it restores and comes forward -- the windows Roost put away, or one window if you minimised them yourself |
| running but not frontmost | it comes forward |
| running with no window open | it opens one, as clicking it in the Dock would |
| already frontmost | every window it has on screen minimises |
| already frontmost, with windows that cannot minimise | it hides |
| already frontmost and full-screen | a notice: macOS cannot minimise a full-screen window |
| marked **launch-only** (Launchpad) | it only ever comes forward, never minimises |

"Frontmost" means the app you were in when you opened the panel, not the panel
itself, so picking the app you were just using puts it away.

### Clicking in the Dock

macOS already launches, raises and restores an app from a Dock click. The one
thing it does not do is answer a click on the app you are **already in** — that
click does nothing at all. Roost fills exactly that gap, so clicking a Dock icon
a second time puts the app away.

Nothing is intercepted. Roost listens and acts afterwards, only in the case
macOS leaves empty, so every other Dock click behaves as it always has. Three
conditions all have to hold, and each one exists because of a bug it prevents:

| Condition | Without it |
|---|---|
| The app was in front **before** the click | a click that *raised* the app would also put it away |
| It had been in front for 0.3 s | the second of two quick clicks would put it away |
| It had a window **on screen** | restoring from the Dock would minimise it again straight away |

Switch it off in **Settings ▸ Search & switcher ▸ The same for a click in the
Dock**. The parent row, **Click an app in front to minimise it**, governs the
search panel and the per-app hotkeys as well — turn that off and a click only
ever brings an app forward.

### Inside the search panel

| Key | Action |
|---|---|
| *(type)* | Filter the list |
| **↓** or **⇥** | Next result |
| **↑** or **⇧⇥** | Previous result |
| **↩** | Activate the selected app (the toggle above) |
| **→** | Open the selected row's options menu — only once the caret has nothing left to walk through, so → still works as a caret key while you are editing the query |
| **⎋** | Close the panel |
| **⌃Space** | Close the panel |

⇥ walks the list the way ⌘⇥ does, so switching apps is one key held and tapped
rather than a reach for the arrows. With an empty query the list is already in
most-recently-used order, so ⌃Space ⇥ ↩ goes back one app.

The mouse: **click** a row to activate it, **right-click** it for the options
menu (with Quit first), or click the **▸** at the row's right edge for the same
menu without Quit at the top.

### Module popup shortcuts

Each monitor module can have a global shortcut that opens its popup. Roost
ships none. Set one on the module's page in Settings: **Keyboard shortcut →
Record Shortcut**, then press the combination.

- It needs at least one of ⌃ ⌥ ⌘ -- a plain key would fire every time you
  typed it -- except the function keys, which can stand alone.
- ⎋ cancels recording; ⌫ removes the shortcut.
- A combination another module already uses is refused, and the button's
  tooltip says which module has it.

Setting the first shortcut is what makes macOS ask for **Input Monitoring**:
watching for a key pressed in another app needs it. With no popup shortcut
set, Roost does not watch the keyboard at all.

Under the hood each is stored as `<Module>_popupShortcut`, a list of key
codes with the modifiers first in the order ⌃ 59, ⇧ 60, ⌘ 55, ⌥ 58 -- the
order a pressed key is matched in, so a hand-written list in another order
never fires.

### The Settings window

| Shortcut | Action |
|---|---|
| **⌘W** | Close the Settings window |
| **⌘Q** | Also closes the Settings window — it does **not** quit Roost |
| **⌘M** | Minimise the Settings window |

To quit Roost, use the **power button** in the Settings window footer.

---

## The search panel

⌃Space (or the trackpad gesture) brings up a Spotlight-like panel. By default it
appears **at the pointer**, not centred; that can be changed in
[Settings](#search--switcher).

**What it lists:** every app on your list, plus every regular app currently
running, deduplicated. So an app does not have to be on your list to be
switched to — the list is for ordering, pinning and hotkeys.

**How it sorts:**

1. **Pinned** entries first, always (Launchpad is pinned out of the box: it is a
   launcher you reach for, not an app you "use", so recency would always bury it).
2. With a query — **relevance**, recency breaking ties.
3. With no query — **most recently used**, so the app you just came from is the
   top hit.

Each row shows the app icon, its name and a dot for its window state: ● running
with a window on screen, ○ running but minimised or hidden, nothing when it is
not running. Apps in your ⌃Tab cycle are marked `⌃⇥`.

### Sums, conversions and actions

When the query is unmistakably one of these, a row appears above the apps:

| You type | The row | ↩ does |
|---|---|---|
| `12*8+5`, `(2+3)*4`, `2^10`, `sqrt(2)`, `10%3` | `12*8+5 = 101` | Copies `101` |
| `5 km in miles`, `72 f to c`, `2 gb in mb`, `10 kg to lb` | `5 km in miles = 3.107 mi` | Copies `3.107 mi` |
| `lock` · `sleep` · `sleep display` · `screen saver` · `dark` · `empty bin` | The action | Runs it |

Sums take `+ - * / % ^`, brackets, `pi`, `e`, and `sqrt abs round floor ceil
sin cos tan ln log`. Conversions cover length, weight, temperature, data,
volume, speed and time, with `in`, `to`, `as` or `into` between the units.

A plain number is not a sum, and actions need three letters, so `sa` still
finds Safari and `sl` still finds Slack. **Empty Bin** asks first, with
Cancel as the default, because it cannot be undone. **Toggle Dark Mode** and
**Empty Bin** go through System Events and Finder, so macOS asks once
whether Roost may control them; **Lock Screen** uses the Accessibility grant.

### The options menu

Right-click a row, or press → , or click the ▸ arrow:

| Item | Notes |
|---|---|
| **Open** / **Bring to Front** | Depending on whether it is running |
| **New Window** | Presses the app's own New Window menu item. A notice says so if the app has none. |
| **Windows** | Listed when the app has more than one. ● is visible, ○ is minimised. Pick one to raise it. |
| **Restore** / **Minimise** / **Hide** | Whichever applies to the current state |
| **Quit** | First in the menu on a right-click |
| **Add to / Remove from ⌃Tab Switcher** | Puts the app in, or takes it out of, the ⌃Tab cycle |
| **Add to / Remove from My Apps** | Puts the app on, or takes it off, your list |
| **Reveal in Finder** | |
| **Copy Bundle ID** | |
| **Add an App…** | File picker; several at once is fine |
| **Edit Apps…** | Opens the Roost Apps window |

The panel has no status-bar menu of its own, so this menu is where the app list
gets managed from.

---

## Managing your app list

**Edit Apps…** (from any row's options menu) opens the **Roost Apps** window:

- **drag** rows to reorder them
- **＋** adds a running app, or browses for one on disk
- **－** removes the selected row
- the small field on the right of each row sets that app's **⌃ shortcut** —
  type one character, or clear it for none

Changes save immediately and hotkeys re-register on the spot, so a removed app
stops answering its ⌃digit straight away.

### apps.json

The list is a JSON file rather than something baked into the binary, so adding
an app can be an edit and a reload rather than a rebuild:

```
~/Library/Application Support/Roost/apps.json
```

It is written with the defaults the first time Roost runs. Each entry:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | What the row says |
| `bundleID` | string | The app's bundle identifier |
| `shortcut` | string or absent | One character, pressed with Control. `"2"` means ⌃2 goes straight here. |
| `launchOnly` | bool | Only ever launch or come forward, never minimise. Launchpad is one of these. |
| `pinned` | bool | Held at the top of the panel regardless of recency or search score |

If the file cannot be read, Roost logs the reason and falls back to the
defaults rather than starting empty.

---

## The trackpad gesture

A trackpad tap opens the search panel. **Three-finger double tap** by default,
with **four-finger** available alongside it in
[Settings → Search & switcher](#search--switcher).

Two fingers is deliberately not offered. macOS makes a two-finger tap a
secondary click and a two-finger double tap Smart Zoom, and this layer can only
observe touches — it cannot swallow them — so every search also fired a
right-click and a zoom.

There is no public API for a global trackpad gesture — the public NSEvent
gesture events only reach the frontmost app's own views — so Roost reads the
private `MultitouchSupport` framework, the same route BetterTouchTool takes.
Deliberately accepted consequences:

- it is undocumented, and Apple can change or remove it
- an app using it cannot ship through the Mac App Store
- it reads finger counts, not events, so it needs no permission (measured with
  Input Monitoring explicitly denied: 459 contact frames in six seconds, and no
  dialog)

To keep the risk small, Roost reads *only* the finger count it is handed, and
never parses the touch struct whose layout changes between macOS releases.

**What counts as a tap:** all fingers down and up again in under 0.25 s, with
the peak finger count being one of the counts that are switched on. A second
tap has to land within 0.45 s **and use the same number of fingers** — a
three-finger tap followed by a four-finger tap is two gestures, not a double
tap. Multi-finger *swipes* keep fingers down far longer, which is what keeps
Mission Control and space switching out of it.

> **macOS claims three-finger taps too** — a three-finger tap is Look Up, and
> this layer cannot swallow it, so it still fires. If it bothers you, switch
> three off and leave **four-finger double tap** on: four is the one count
> nothing stock claims.

---

## The system monitor

### Modules

Six modules, each switched on or off in the Settings sidebar:

| Module | In the menu bar by default | In its popup |
|---|---|---|
| **CPU** | total load | load history, every core (efficiency and performance clusters apart), user/system split, load average, temperature, limits when macOS is throttling, top processes |
| **GPU** | utilisation | utilisation history, renderer and tiler, memory in use, every accelerator on a Mac with more than one |
| **RAM** | used % | breakdown bar (app, wired, compressed, cached, free), memory pressure, swap, top processes |
| **Disk** | used % of the watched volume | capacity bar, read/write activity, every other volume, per-device totals |
| **Network** | upload and download | online status and latency, Wi-Fi signal, traffic history, reachability, local IP, top processes |
| **Sensors** | the watched sensor | every temperature, voltage, current, power and fan reading your Mac publishes, grouped by kind |

Sensors is the expensive one: reading every sensor walks the whole controller
table. If you want to cut Roost's energy use, switch it off first.

### Menu bar shapes

Each module draws one or more shapes, chosen on its page in Settings. Not every
shape suits every reading, so each module offers only the ones it can fill:

| Shape | Shows |
|---|---|
| **Name** | The module's short label |
| **Figure** | A caption over one number — the default for most modules |
| **Line chart** | A rolling line of recent values |
| **Bar chart** | One bar per core |
| **Ring** | A filled ring, split into parts where the reading has them |
| **Gauge** | A dial |
| **Used and free** | Two figures stacked |
| **Rates** | Upload and download, each with its arrow |
| **Traffic chart** | Upload above a line, download below it |

Numbers are coloured by how hard the reading is working — **teal** when calm,
**amber** when busy, **red** when it needs you — and turn bold once they are
flagged. Each module judges by its own scale: a disk is flagged at 90% full,
not 50%; memory follows macOS's own memory pressure rather than the percentage;
a temperature is flagged at 85 °C. The three colours, and whether the menu bar
is coloured at all, are in [Settings → Colours](#colours).

Separate items are ordered by macOS, not Roost. To rearrange them, hold **⌘**
and drag an item along the menu bar.

### Popups

**Click a reading** to open its popup. Every popup opens the same way: a
one-line verdict with a coloured dot (**● Light load**, **● Pressure warning**,
**● Online · Wi-Fi · 65 ms**), the headline figures, then a chart or bar of the
reading, then the detail. Rows you need once — a model name, a mount point, a
hardware address — are folded under **More details**, which remembers whether
you left it open.

The **⚙︎ gear** in the popup header opens that module's page in Settings.

A popup closes when you click anywhere else or press **⎋**. It scrolls with the
trackpad or wheel when it is taller than the screen allows.

### Combined modules

**Settings → Menu bar → Combine modules into one item** folds the modules into
a single menu bar item. Once it is on, you can choose the **Spacing**, add
**Separators**, and turn on **One popup for all**, which opens a single popup
showing every module at once.

### Alerts

A module can notify you when a reading crosses a line you set, under **Notify
me when** on its page in Settings:

| Module | Thresholds |
|---|---|
| **CPU** | total, system, user, efficiency-cores and performance-cores load |
| **RAM** | memory used, memory free, memory pressure, swap |
| **GPU** | utilisation |
| **Disk** | disk usage |

**One busy app.** Also on the CPU page: **One app stays this busy for 5
minutes**, on by default at 50% (of one core, as Activity Monitor counts it).
It watches each app on its own -- an app can hold half a core while the
machine as a whole looks quiet -- and folds helpers into their app, so
Chrome's renderers are Chrome. The alert has a **Quit** button for an app,
which asks it to quit the way ⌘Q does, so unsaved work still gets to ask. A
command-line tool or system process is named, with a pointer to Activity
Monitor, and no button. It is reported once per busy stretch, not every
half minute.

**Throttling.** When macOS slows the processor down to cool it -- a fanless
MacBook Air under sustained load does -- the CPU popup's status line says
**Throttling** (or **Throttling hard**), and the CPU figure in the menu bar
turns amber or red even at a low load, because a held-back Mac feels slow
whatever the percentage says. One step earlier it adds **warming up**. This is
macOS's own thermal state, not a guess from a temperature. **The Mac slows
down to cool off** on the CPU page sends one notification as it starts.

**Network** works the other way, under **Tell me when**: it notifies you when
the interface, the local IP, the Wi-Fi network or the public IP changes. The
public IP is only looked up when **Look up the public address** is on; see
[Privacy](#privacy).

Alerts keep working while every popup is closed — that is when a change is most
likely to go unnoticed.

---

## Clipboard history

Roost can keep what you copy, text and images, so you can use it again. It is
**off until you turn it on**: Settings ▸ Clipboard ▸ **Enable clipboard
history**, which explains first what is kept and where.

**Two separate switches.** *Enable clipboard history* decides whether copies
are kept. The **Clipboard** switch in the sidebar decides whether it has an
item in the menu bar. History keeps working with the item hidden.

**The menu bar item** is an icon beside the other readings, faded while
history is off. Click it for the latest copies:

- Type to search; **↑ ↓** move the highlight; **Return** or a click copies the
  entry back to the clipboard, ready for **⌘V**.
- Right-click an entry to copy, pin or delete it.
- **View All…** opens the full history; the **⚙︎** opens its settings.

In combined mode with **One popup for all**, the clipboard is a tile in that
popup instead.

**The history window** lists everything, newest first, with a search (text,
the app that was in front, image sizes) and **All / Text / Images / Pinned**.
Select an entry to see all of it. **Return** copies it, **Space** pins it, **⌫**
deletes it, and **Clear** removes unpinned entries or everything, after a
confirmation.

**Restoring** puts back every form that was kept: plain text, its RTF and HTML
formatting, a link, an image as PNG and TIFF, or files as files. If a stored
form has gone missing, Roost says that only the text went back.

**Paste for me** (off by default) also sends ⌘V to the app you were in. It
needs the same window-control permission the switcher uses; without it, the
entry is copied and you paste it yourself. Roost says it *sent* ⌘V, because it
cannot see whether the app took it.

| Setting | Default | |
|---|---|---|
| Text, links and files | On | |
| Keep formatting | On | RTF and HTML with the text |
| Images | On | Up to 25 MB each; larger ones are left out, not shrunk |
| Keep at most | 200 | Not counting pinned entries |
| Remove entries after | 30 days | Pinned entries stay unless **Pinned entries expire too** |
| Keep history after quitting | On | Off deletes it when Roost quits |
| Clear unpinned entries when Roost quits | Off | |
| Entries in the popup | 8 | |
| Keyboard shortcut | none | Opens the popup, or the history window while the item is hidden |

**Never kept, whatever the settings:** anything an app marks as concealed,
transient or auto-generated (the [nspasteboard.org](http://nspasteboard.org)
markers that password managers use), and copies made while an app on the
**Ignore copies made in** list is in front. That list starts with the common
password managers. Roost can tell which app was *in front* when something was
copied, not which app wrote it.

**macOS may ask** whether Roost can read what you copy (System Settings ▸
Privacy & Security ▸ Paste from Other Apps). Choose **Allow**; if it is set to
deny, history shows as **Blocked by macOS**.

---

## Settings

Open Settings from the **⚙︎** in any popup. The window has a sidebar in three
groups: **Overview**, **Free up space** and **Search & switcher**; then
**Monitoring**, one page per module with its on/off switch (a module that is
off is dimmed); then **Settings**. The search field at the top filters all of
them.

### Overview

How the Mac is doing now, from the readings the modules already take — the
Overview samples nothing of its own.

- **The header** names the Mac and its macOS release, and says in one line
  whether anything needs looking at. It is drawn only from modules that are
  on.
- **Issues** appear only when there is one: sustained heavy CPU load (ten
  seconds at 80% or more), macOS slowing the processor to cool it, memory
  *pressure* raised or critical (the kernel's own level, not how full memory
  is), the watched volume past 90% or 95%, or no network interface up. Each
  has a **Details** button to the module's page.
- **Cards** for CPU, Memory, Disk and Network, each with its figure, its
  verdict in words, recent history and two or three supporting figures. Click
  a card to open that module's page. A module that is off says so and offers
  **Turn On**; one whose every menu bar shape is off says it is not being
  measured, because Roost samples what the menu bar shows.
- **Battery health** (on a Mac with a battery) shows the maximum capacity,
  cycle count and condition exactly as System Settings ▸ Battery reports them,
  read every half hour while the Dashboard is open, with the current charge and
  whether it is charging. A figure macOS does not report is shown as "Not
  reported", never estimated.
- **Customize** chooses which cards show — GPU and Sensors are available but
  hidden by default — and their order, with **Restore Defaults**.
- **About this Mac** is folded away until opened. *Hardware* lists the model,
  processor and cores, memory, graphics, storage, each display's own panel
  resolution and fastest refresh rate, the model identifier, the production
  year where the name carries one, and the serial number — masked to its last
  four characters, with buttons to show and copy it. *Right now* lists the
  macOS release and build, uptime, and each display's current mode: the size
  it looks like, the resolution it is drawn at when that differs, and its
  refresh rate.

A macOS release Roost does not know the name of is shown by its number alone
(“macOS 27.0”) rather than given the last name it knew.

### Module pages

Each module's page has its menu bar shapes, its alerts, and settings of its
own — chart history length and how many top processes to list for most;
**Show temperature** for CPU; the watched volume and **Include removable
drives** for Disk; the watched sensor, the reading interval, which sensors show
in the popup and **Read the HID sensors** for Sensors.

### General

| Setting | Default | Notes |
|---|---|---|
| **Start at login** | Off | |
| **Show in Dock** | Off | Roost is a menu bar app; this gives it a Dock icon too |
| **Check for updates** | Once per day | Also: Never, Once per hour, Once per week, and **Silent** |
| **Temperature unit** | System | Celsius, Fahrenheit, or whatever macOS uses |

> **"Silent" is not a quiet check.** It downloads the release and installs it,
> replacing the running application without asking. The default is a daily
> check that tells you and waits.

### Menu bar

| Setting | Default | Notes |
|---|---|---|
| **Combine modules into one item** | Off | Then **Spacing**, **Separators** and **One popup for all** — see [Combined modules](#combined-modules) |
| **Keep item positions** | Off | Remembers where each item sat, rather than letting macOS reshuffle them |

### Colours

| Setting | Default | Notes |
|---|---|---|
| **Colour the menu bar** | On | Off draws every figure and arrow in the menu bar's own colour. The popups keep their colours either way. |
| **Normal** | `#0E9BA8` teal | A calm reading |
| **Busy · upload and write** | `#CE7C00` amber | A busy reading; also the upload and disk-write series |
| **Critical** | `#C9302C` red | A reading that needs you |

Each colour has a colour well, which opens the macOS colour picker, and a field
that takes a hex code (`#RRGGBB` or `#RGB`). The reset arrow beside a changed
colour restores the default. Changes apply immediately.

### Search & switcher

Its own page in the sidebar. **Keyboard** lists each global key and whether
Roost holds it: a key another app registered first stays that app's, and the
row says “taken by another app” instead. If ⌃Tab is taken, the cycle uses ⌥Tab
and the row says so. **Edit apps…** opens the app list.

| Setting | Default | Notes |
|---|---|---|
| **⌃Tab cycles your marked apps** | On | Off gives ⌃Tab back to every other app |
| **Open where the pointer is** | On | Off centres the panel on the screen |
| **Close when it loses focus** | On | Off keeps the panel up while you click elsewhere; ⎋ and ⌃Space still close it |
| **Click an app in front to minimise it** | On | In the search and with an app's own shortcut |
| **Click an app in the Dock to minimise it** | On | A separate setting; needs window control |
| **Trackpad gesture opens the search** | On | Then **Three-finger double tap** (on) and **Four-finger double tap** (off) |
| **Window control** | — | Shows whether Accessibility is granted, with **Allow…** when it is not |

These are also plain preferences, if you would rather use Terminal — change
one, then restart Roost:

| Key | Type | Default |
|---|---|---|
| `openAtPointer` | bool | `true` |
| `hideOnOutsideClick` | bool | `true` |
| `cycleHotkeyEnabled` | bool | `true` |
| `gestureEnabled` | bool | `true` |
| `gestureFingerCounts` | array of int | `[3]` — 3 and 4 are allowed |
| `gestureTaps` | int | `2` |

```bash
# four-finger double tap only, leaving three to macOS's Look Up
defaults write com.sagar.roost gestureFingerCounts -array 4

# give Ctrl+Tab back to your browser
defaults write com.sagar.roost cycleHotkeyEnabled -bool false
```

### Permissions

**Window control** (Accessibility) is what the switcher needs to bring windows
forward. **Alerts** (Notifications) is asked for the first time an alert is
due, and has a button to its page in System Settings.

### Help

**Welcome tour** opens the first-run window again. Walking through it changes
nothing: each choice starts on the current setting and is written only when
clicked. **User manual** opens this document.

### Backup

**Export…** writes every Roost setting to a file. **Import…** reads one back and
offers to restart Roost so every setting takes effect. **Reset…** returns
everything to the defaults after a confirmation, and restarts Roost.

### The footer

| Button | Action |
|---|---|
| ♥ **Support** | Opens Roost's Ko-fi page |
| 🐜 **Report a bug** | Opens a new GitHub issue |
| ⏸ **Pause** | Switches every module off and leaves a single Roost icon in the menu bar; click it to reopen Settings. Press again to resume — the modules that were on come back on. |
| ⏻ | Quits Roost |

---

## Where Roost keeps things

| Path | What |
|---|---|
| `~/Library/Application Support/Roost/apps.json` | The launcher's app list |
| `~/Library/Application Support/Roost/Clipboard/` | Clipboard history: `index.json`, and `payloads/` for images and formatting. Readable by your account only; not encrypted beyond your account and FileVault. Deleted entries take their files with them |
| `com.sagar.roost` (UserDefaults) | Every setting — both halves |

Roost installs no helper, daemon or extension.

---

## Privacy

Roost collects no telemetry or analytics and has no account. Clipboard
history never leaves the Mac, and its content is never written to a log. It
talks to the network in three cases:

- **Update check** — a plain read of
  `https://api.github.com/repos/sagardn/Roost/releases/latest`, on the schedule
  set in **Check for updates**. Nothing about your Mac is sent. **Never** stops it.
- **Connectivity check** — while the Network popup is open, a TCP handshake
  with `1.1.1.1` on port 53, every few seconds, to measure latency and whether
  the internet answers. No data is sent over it.
- **Public IP** — `https://ifconfig.co/json`, while **Look up the public
  address** is on in the Network module. **It is on by default.** The request
  is made when the Network popup opens, every two minutes for as long as it
  stays open, and again when the connection changes — not on a background
  timer, and never while the popup is closed. The reply carries your public
  address and the country and network operator that address belongs to, which
  is what the row shows; nothing about your Mac is sent to get it. Switch
  **Look up the public address** off and no request is made at all.

  `ifconfig.co` runs [echoip](https://github.com/mpolden/echoip), which is
  open source and self-hostable if you would rather not depend on someone
  else's server; repoint the endpoint in `Roost/Monitor/NetworkInfo.swift`.

---

## Troubleshooting

**No Roost items in the menu bar at all.** On macOS 26 and newer: System
Settings → Menu Bar → turn Roost on. If you see `«` among your menu bar icons,
macOS is hiding items that do not fit, newest first — quit another menu bar app
or ⌘-drag items to make room. Finally, check the module is switched on in the
Settings sidebar.

**Nothing minimises; apps only come forward.** Accessibility is not granted, or
was granted to an earlier build — see [Permissions](#permissions). Raising an
app needs no permission, minimising one does.

**The gesture does nothing.** Check which finger counts are switched on in
Settings → Search & switcher: the default is three, not two or four. No
permission is involved. If Roost could not read the trackpad at all, it turns
the setting off and says so.

**⌃Tab stopped working in my browser.** That is Roost holding it globally.
Switch off **⌃Tab cycles your marked apps** in Settings → Search & switcher.

**A hotkey does nothing.** Another app registered it first — macOS gives a
global hotkey to whoever asked first and tells the loser nothing. Roost names
the shortcuts it could not claim in a notice at launch. Quit the app that owns
the key, pick a different character in Roost Apps, or look for a clash in
System Settings → Keyboard → Keyboard Shortcuts….

**A popup shortcut does nothing.** Check the key codes are in the order ⌃ ⇧ ⌘ ⌥
then the key, that Roost was restarted, and that Input Monitoring is granted —
see [Module popup shortcuts](#module-popup-shortcuts).

**"macOS can't minimise a full-screen window."** It cannot, and hiding the app
instead was tried and rejected: ⌘H tears down the full-screen space, after
which the app reports no windows and nothing can bring it back.

**Roost uses too much CPU or battery.** Switch off the modules you do not need,
starting with Sensors.

**Sensors show the wrong core count.** CPU and GPU sensors are thermal zones,
not cores. "CPU Efficient Core 1" is one sensor inside the efficiency cluster,
not one core's temperature.

**A sensor shows an impossible reading** (−2 °C, or a jump far above its
neighbours). Some sensor keys report raw or uncalibrated values. Hide it under
the Sensors page's popup list, and if another sensor beside it agrees with the
high value, the reading is real.

---

## Uninstalling

Run the script bundled with the app, as yourself rather than with `sudo` —
Roost installs no helper, so nothing it removes needs administrator rights:

```bash
sh /Applications/Roost.app/Contents/Resources/Scripts/uninstall.sh
```

It quits Roost and removes `Roost.app`, the application data and preferences
listed above, and the Accessibility and notification permissions macOS keeps
for it. If the app has already gone to the Trash, the same script can be run
from the repository:

```bash
sh Tools/uninstall.sh
```
