//
//  widget-test.swift
//
//  Exercises the menu bar renderer: the six shapes, their widths, and the
//  stored style list.
//
//  Run:  cat Roost/UI/Palette.swift Roost/UI/Localized.swift \
//            Roost/Startup/FormerName.swift Roost/Settings/Preferences.swift Roost/Monitor/MenuBarStyle.swift \
//            Roost/Monitor/MenuBarWidget.swift Roost/Monitor/Readings.swift \
//            Tools/widget-test.swift | swift -
//
//  Writes /tmp/menu-bar-<style>.png and /tmp/menu-bar-row.png, because a
//  shape is the one thing an assertion cannot check. A view renders into a
//  bitmap without a window, so this works on a machine whose screen is
//  locked -- which is more than can be said for the menu bar itself.
//
//  Two things about rendering offscreen, both found the hard way: an
//  appearance has to be set or every dynamic colour resolves to nothing, and
//  the bitmap starts transparent so it needs filling before the view draws.
//
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// Unbuffered, because the thing this file is for is finding a draw that
// crashes, and a crash takes buffered output with it -- which is how the
// first run of this looked like a crash in the first style when it was
// really the last.
setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

/// A busy eight-core machine, working its performance cluster: the shape that
/// exercises every part of every style.
// Explicitly typed, and the sine lifted out of the expression. Both are for
// the type checker rather than the reader: as one inferred expression this
// took 373ms to solve here and timed out entirely on a CI runner, which is
// slower. `swiftc -Xfrontend -warn-long-expression-type-checking=150` is how
// to find the next one.
let cores: [Double] = [0.11, 0.17, 0.08, 0.21, 0.88, 0.94, 0.79, 0.91]
let history: [Double] = (0..<60).map { (i: Int) -> Double in
    let phase = sin(Double(i) / 7)
    return 0.2 + 0.45 * phase * phase
}
let reading = MenuBarReading(
    label: "CPU",
    load: 0.52,
    value: "52%",
    history: history,
    bars: cores,
    segments: [.init(0.18, .roostMagenta), .init(0.34, .roostBlue)],
    pair: .init("13.0 GB", "3.0 GB")
)

/// The same reading from a module with only one figure to report -- which is
/// most of them. The shape that stacks a pair must take no room at all.
let single = MenuBarReading(label: "CPU", load: 0.52, value: "52%",
                            history: history, bars: cores)

/// What network reports: two rates and two series, and no percentage at all.
// The two series are locals with declared types for the same reason. Inline
// inside the nested .init this was the 1137ms expression that failed to
// compile on CI at all, and took widget-test -- and so the whole tests
// workflow -- red with it from the day the workflow was added.
let upward: [Double] = (0..<30).map { Double($0) * 1000 }
let downward: [Double] = (0..<30).map { Double(30 - $0) * 4000 }
let rates = MenuBarReading(
    label: "NET",
    value: "1.2 MB/s",
    rates: .init("240 KB/s", "1.2 MB/s"),
    mirrored: .init(up: upward, down: downward))

func widget(_ styles: [MenuBarStyle], _ content: MenuBarReading?) -> MenuBarWidget {
    let w = MenuBarWidget()
    w.styles = styles
    w.content = content
    w.frame = NSRect(x: 0, y: 0,
                     width: max(1, w.intrinsicContentSize.width),
                     height: MenuBarMetrics.height)
    return w
}

/// The menu bar's own dark grey, which is what these shapes are seen
/// against.
///
/// A view rather than a fill into the bitmap beforehand: a graphics context
/// made from a cached-display bitmap can come back nil, and filling with no
/// current context throws from inside the draw -- which is what the first
/// version of this did. A backdrop view cannot fail that way.
final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.18, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

/// Renders a shape on the menu bar's grey and reports how many pixels it
/// actually put down.
func render(_ view: NSView, to path: String) -> Int {
    let backdrop = Backdrop(frame: view.bounds)
    backdrop.appearance = NSAppearance(named: .darkAqua)
    backdrop.addSubview(view)
    guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)
    else { return 0 }
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)

    // Count the pixels that are not the background. A style that silently
    // drew nothing is the failure this catches -- it looks identical to a
    // style that drew correctly in every assertion about width.
    var drawn = 0
    for x in 0..<rep.pixelsWide {
        for y in 0..<rep.pixelsHigh {
            // Converted first: a bitmap's colour comes back in the bitmap's
            // own space, and asking a tagged non-grey colour for its white
            // component throws rather than converting.
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
            else { continue }
            let off = abs(c.redComponent - 0.18) + abs(c.greenComponent - 0.18)
                    + abs(c.blueComponent - 0.18)
            if off > 0.09 { drawn += 1 }
        }
    }
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    return drawn
}

// MARK: - Widths

print("MenuBarMetrics")

check("a bold 100% fits the figure", MenuBarMetrics.figureWidth >= 31.8 + 4)
check("the name is one glyph wide", MenuBarMetrics.labelWidth < 12)
check("one bar still looks like a bar", MenuBarMetrics.barChartWidth(bars: 1) >= 10)
// 3pt bars a point apart: eight cores come to 35, against the 40 the shape
// this replaces always took whatever the core count. Narrower is the right
// direction in a place measured in single points.
check("eight bars are no wider than the shape they replace",
      MenuBarMetrics.barChartWidth(bars: 8) <= 40)
check("a 64-core machine does not take the whole bar",
      MenuBarMetrics.barChartWidth(bars: 64) <= 122)
check("no bars is treated as one", MenuBarMetrics.barChartWidth(bars: 0)
                                == MenuBarMetrics.barChartWidth(bars: 1))
check("a negative count does not crash or go negative",
      MenuBarMetrics.barChartWidth(bars: -5) > 0)
check("the ring and the gauge are square to the drawing height",
      MenuBarMetrics.dialWidth == MenuBarMetrics.drawHeight + 4)

// The clipboard's reading: an icon and nothing else.
let icon = MenuBarReading(label: "CLIP", symbol: "doc.on.clipboard")

print("\nWidget widths")

for style in MenuBarStyle.allCases {
    let source = [.rates, .trafficChart].contains(style) ? rates
        : style == .symbol ? icon : reading
    let w = widget([style], source)
    check("\(style.rawValue) is positive and sane: \(Int(w.intrinsicContentSize.width))pt",
          w.intrinsicContentSize.width > 4 && w.intrinsicContentSize.width < 130)
}

do {
    check("a module with no pair takes no room for the shape that stacks one",
          widget([.pair], single).intrinsicContentSize.width == 0)
    // Storage is the one module that wants both pairs, and they are not the
    // same two numbers: used and free is what it holds, read and write is
    // what it is doing.
    check("the rate shape reads the rates, not the pair",
          widget([.rates], MenuBarReading(label: "SSD", pair: .init("a", "b")))
            .intrinsicContentSize.width == 0)
    check("and the pair shape reads the pair, not the rates",
          widget([.pair], MenuBarReading(label: "SSD", rates: .init("a", "b")))
            .intrinsicContentSize.width == 0)
    check("nor for the shapes network uses",
          widget([.rates, .trafficChart], single).intrinsicContentSize.width == 0)
    check("and draws nothing for it",
          render(widget([.pair], single), to: "/tmp/menu-bar-nopair.png") == 0)
    check("while the rest of its shapes are unaffected",
          widget([.mini, .pair], single).intrinsicContentSize.width
            == MenuBarMetrics.figureWidth)
}

do {
    // Every shape at once, from a reading that can fill all of them.
    let everything = MenuBarReading(
        label: "CPU", load: 0.52, value: "52%", history: history, bars: cores,
        segments: [.init(0.18, .roostMagenta), .init(0.34, .roostBlue)],
        pair: .init("13.0 GB", "3.0 GB"),
        rates: .init("240 KB/s", "1.2 MB/s"),
        mirrored: .init(up: (0..<20).map { Double($0) }, down: (0..<20).map { Double(20 - $0) }),
        symbol: "doc.on.clipboard")
    let all = widget(MenuBarStyle.allCases, everything)
    let sum = MenuBarStyle.allCases.reduce(0.0) {
        $0 + MenuBarMetrics.width(of: $1, bars: cores.count)
    }
    check("several shapes are as wide as their sum",
          abs(all.intrinsicContentSize.width - sum) < 0.5)
    check("nothing switched on is nothing wide",
          widget([], reading).intrinsicContentSize.width == 0)
    check("a rate pair is as wide as its own shape",
          abs(widget([.rates], rates).intrinsicContentSize.width
              - MenuBarMetrics.ratesWidth) < 0.5)
    check("a traffic chart is as wide as a line chart",
          widget([.trafficChart], rates).intrinsicContentSize.width
            == MenuBarMetrics.chartWidth + 4)
    check("no sample yet is still a sane width",
          widget([.mini], nil).intrinsicContentSize.width == MenuBarMetrics.figureWidth)
}

// MARK: - Drawing

print("\nEvery shape draws something")

for style in MenuBarStyle.allCases {
    let source = [.rates, .trafficChart].contains(style) ? rates
        : style == .symbol ? icon : reading
    let w = widget([style], source)
    let drawn = render(w, to: "/tmp/menu-bar-\(style.rawValue).png")
    check("\(style.rawValue) put \(drawn) pixels down", drawn > 20)
}

do {
    let row = widget([.label, .mini, .lineChart, .barChart, .pieChart, .tachometer, .pair],
                     reading)
    let netRow = widget([.label, .rates, .trafficChart], rates)
    check("network's own row draws", render(netRow, to: "/tmp/menu-bar-net.png") > 100)
    check("the whole row draws", render(row, to: "/tmp/menu-bar-row.png") > 200)

    // An empty reading must not crash any of the six, and must not pretend.
    let bare = MenuBarReading(label: "CPU", load: 0, value: "—")
    let empty = widget(MenuBarStyle.allCases, bare)
    check("an empty reading draws without crashing",
          render(empty, to: "/tmp/menu-bar-empty.png") > 0)

    // Out-of-range values are what a reader returns when something is wrong.
    let wild = MenuBarReading(label: "CPU", load: 4.2, value: "420%",
                              history: [-1, 2, .nan, 0.5],
                              bars: [-0.5, 1.9, 0.3],
                              segments: [.init(9, .roostBlue), .init(-3, .roostMagenta)],
                              pair: .init("?", "?"),
                              rates: .init("?", "?"),
                              mirrored: .init(up: [.nan, -5, .infinity],
                                              down: [0, .nan, 1]))
    let rough = widget(MenuBarStyle.allCases, wild)
    check("an impossible reading does not crash",
          render(rough, to: "/tmp/menu-bar-wild.png") > 0)
}

// MARK: - The stored style list

print("\nMenuBarStyles")

let defaults = UserDefaults(suiteName: "com.sagar.roost.widget-test")!
defaults.removePersistentDomain(forName: "com.sagar.roost.widget-test")

check("the key is the one the old module system wrote",
      MenuBarStyles.key("CPU") == "CPU_widget")

check("nothing stored is the module's own default",
      MenuBarStyles.stored(for: "NoSuchModuleXYZ") == [.mini])
check("nothing stored honours a given default",
      MenuBarStyles.stored(for: "NoSuchModuleXYZ", default: [.pieChart]) == [.pieChart])

UserDefaults.standard.set("line_chart", forKey: "WidgetTestA_widget")
check("one stored name reads back",
      MenuBarStyles.stored(for: "WidgetTestA") == [.lineChart])

UserDefaults.standard.set("mini,line_chart", forKey: "WidgetTestB_widget")
check("a list reads back", MenuBarStyles.stored(for: "WidgetTestB") == [.mini, .lineChart])

UserDefaults.standard.set("speed", forKey: "WidgetTestJ_widget")
check("the name the old module system used for the rates shape still reads",
      MenuBarStyles.stored(for: "WidgetTestJ") == [.rates])
UserDefaults.standard.set("network_chart", forKey: "WidgetTestK_widget")
check("and the one it used for the traffic chart",
      MenuBarStyles.stored(for: "WidgetTestK") == [.trafficChart])

UserDefaults.standard.set("line_chart,mini", forKey: "WidgetTestC_widget")
check("the order drawn is fixed, not the order stored",
      MenuBarStyles.stored(for: "WidgetTestC") == [.mini, .lineChart])

UserDefaults.standard.set("mini,mini,mini", forKey: "WidgetTestD_widget")
check("a repeat is one shape", MenuBarStyles.stored(for: "WidgetTestD") == [.mini])

// "speed" and "network_chart" are shapes now; "battery" and "sensors" are
// still another module's vocabulary, and a module that cannot draw them
// should not be asked to.
UserDefaults.standard.set("mini,battery,sensors", forKey: "WidgetTestE_widget")
check("names from another module's vocabulary are dropped",
      MenuBarStyles.stored(for: "WidgetTestE") == [.mini])

UserDefaults.standard.set("battery,sensors", forKey: "WidgetTestF_widget")
check("nothing recognisable falls back rather than blanking the bar",
      MenuBarStyles.stored(for: "WidgetTestF") == [.mini])

UserDefaults.standard.set("", forKey: "WidgetTestG_widget")
check("an empty value means nothing in the menu bar",
      MenuBarStyles.stored(for: "WidgetTestG") == [])

UserDefaults.standard.set(" mini , pie_chart ", forKey: "WidgetTestH_widget")
check("whitespace around a name is tolerated",
      MenuBarStyles.stored(for: "WidgetTestH") == [.mini, .pieChart])

UserDefaults.standard.set(42, forKey: "WidgetTestI_widget")
check("a value of the wrong type falls back",
      MenuBarStyles.stored(for: "WidgetTestI") == [.mini])

check("an icon reading takes only the icon's width",
      widget([.symbol, .mini], MenuBarReading(label: "X", symbol: "doc.on.clipboard")).intrinsicContentSize.width
        == MenuBarMetrics.symbolWidth + MenuBarMetrics.figureWidth)
check("a reading with no icon takes no room for one",
      widget([.symbol], reading).intrinsicContentSize.width == 0)
check("the icon is left out of the shared shape list",
      MenuBarStyle.special.contains(.symbol))
check("every style has a name for the settings page",
      MenuBarStyle.allCases.allSatisfy { !$0.title.isEmpty })

for key in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K"] {
    UserDefaults.standard.removeObject(forKey: "WidgetTest\(key)_widget")
}

print("\nRate tints")

check("an idle link sits at the faint end", RateTint.intensity(0) == 0)
check("the floor is still faint", RateTint.intensity(RateTint.floor) == 0)
check("the ceiling is full strength", RateTint.intensity(RateTint.ceiling) == 1)
check("past the ceiling stays full", RateTint.intensity(1e9) == 1)
check("NaN does not reach the draw", RateTint.intensity(.nan) == 0)
check("each decade is a quarter", abs(RateTint.intensity(10_000) - 0.25) < 1e-9
      && abs(RateTint.intensity(1_000_000) - 0.75) < 1e-9)

func saturation(_ c: NSColor) -> CGFloat {
    let s = c.usingColorSpace(.sRGB)!
    return max(s.redComponent, s.greenComponent, s.blueComponent)
        - min(s.redComponent, s.greenComponent, s.blueComponent)
}
for ink in [NSColor.white, .black] {
    let name = ink == .white ? "dark bar" : "light bar"
    check("\(name): rate figures carry no hue",
          [0, 5e7].allSatisfy { saturation(RateTint.figure($0, ink: ink)) < 0.01 })
    check("\(name): a busy figure is brighter than an idle one",
          RateTint.figure(5e7, ink: ink).alphaComponent > RateTint.figure(0, ink: ink).alphaComponent)
    check("\(name): an idle figure is still readable",
          RateTint.figure(0, ink: ink).alphaComponent >= 0.6)
}

var tinted = MenuBarReading.Pair("1 KB/s", "2 KB/s")
tinted.speeds = .init(upload: 1, download: 2)
var faster = tinted
faster.speeds = .init(upload: 1, download: 2_000_000)
check("a change in speed alone redraws", tinted != faster)

print("\nSeverity")

check("the ramp: 49% is calm", MenuBarReading.Severity.of(load: 0.49) == .calm)
check("the ramp: 50% warns", MenuBarReading.Severity.of(load: 0.50) == .warning)
check("the ramp: 80% is critical", MenuBarReading.Severity.of(load: 0.80) == .critical)
check("the ramp: NaN is calm", MenuBarReading.Severity.of(load: .nan) == .calm)
check("a disk 85% full is calm", MenuBarReading.Severity.ofDisk(0.85) == .calm)
check("a disk 90% full warns", MenuBarReading.Severity.ofDisk(0.90) == .warning)
check("a disk 95% full is critical", MenuBarReading.Severity.ofDisk(0.95) == .critical)
check("65 °C is calm", MenuBarReading.Severity.ofTemperature(65) == .calm)
check("85 °C warns", MenuBarReading.Severity.ofTemperature(85) == .warning)
check("95 °C is critical", MenuBarReading.Severity.ofTemperature(95) == .critical)
check("a stated severity beats the load",
      MenuBarReading(label: "RAM", load: 0.82, severity: .calm).resolvedSeverity == .calm)
check("no stated severity falls back to the load",
      MenuBarReading(label: "CPU", load: 0.82).resolvedSeverity == .critical)

let flagged = ("100%" as NSString).size(withAttributes: [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
check("a flagged 100% fits the figure slot",
      flagged <= MenuBarMetrics.figureWidth - MenuBarMetrics.padding * 2 + 0.01)

print("\nRates fit")

// The unit used to wrap off the bottom of the item: "17.0 KB/s" is wider
// than the "999 MB/s" the slot was measured against. Every rate the
// formatter can produce has to fit beside the arrow column.
let rateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
let slot = MenuBarMetrics.ratesWidth - 9 - MenuBarMetrics.padding * 2
var widest = ("", CGFloat(0))
for exponent in stride(from: 0.0, through: 12.0, by: 0.01) {
    for rate in [pow(10, exponent), pow(10, exponent) * 1.0237, 1023.9 * pow(1024, exponent.rounded(.down) / 3)] {
        let text = Readings.rate(rate)
        let width = (text as NSString).size(withAttributes: [.font: rateFont]).width
        if width > widest.1 { widest = (text, width) }
    }
}
check("every rate fits its slot (widest \(widest.0), \(widest.1) of \(slot))",
      widest.1 <= slot)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
