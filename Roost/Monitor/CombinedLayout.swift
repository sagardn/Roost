import CoreGraphics

/// Where each module's reading sits inside one shared menu bar item.
///
/// Arithmetic only, and deliberately kept away from the views. The parts of
/// combined mode that go wrong are the parts nobody can see in a screenshot:
/// a click landing on the module to the left of the one you pressed, a
/// separator counted for a reading that is switched off, a width that drifts
/// by a point every time a value ticks. All of that is decided here, where it
/// can be checked on a machine with no menu bar at all --
/// see `Tools/combined-test.swift`.
///
/// The geometry is the one combined mode has always drawn, kept to the point:
/// readings left to right in order, `spacing` between them, and when
/// separators are on a hairline in the gap that reserves three points of its
/// own. Anyone who has tuned their menu bar around it keeps what they tuned.
struct CombinedLayout: Equatable {

    /// What a module reports before it is placed: its name, and how wide its
    /// reading is right now.
    struct Measurement: Equatable {
        let name: String
        let width: CGFloat

        init(_ name: String, _ width: CGFloat) {
            self.name = name
            self.width = width
        }
    }

    /// One module's place in the row.
    struct Slot: Equatable {
        let name: String
        let x: CGFloat
        let width: CGFloat

        var maxX: CGFloat { x + width }
    }

    /// A separator, by its left edge.
    struct Rule: Equatable {
        let x: CGFloat
    }

    let slots: [Slot]
    let rules: [Rule]
    /// What the status item's length must be.
    let width: CGFloat

    /// The line is a hairline, but it reserves three points so it does not
    /// sit flush against the readings on either side.
    static let ruleWidth: CGFloat = 1
    static let ruleFootprint: CGFloat = 3

    /// `measurements` are in display order.
    ///
    /// Anything with no width is dropped here rather than trusted to have
    /// been filtered out already. A zero-width slot is worse than useless:
    /// it claims a separator and two gaps for a reading nobody can see, and
    /// because the hit test takes the last slot starting at or before the
    /// press, a stack of them at the same x swallows the press meant for the
    /// reading that is actually there. Measured: a module still starting up
    /// reports zero for a second or two.
    init(of measurements: [Measurement],
         spacing: CGFloat = 0,
         separators: Bool = false) {
        var slots: [Slot] = []
        var rules: [Rule] = []
        var x: CGFloat = 0

        for (index, measurement) in measurements.filter({ $0.width > 0 }).enumerated() {
            if index != 0 {
                x += spacing
                if separators {
                    rules.append(Rule(x: x))
                    x += Self.ruleFootprint + spacing
                }
            }
            slots.append(Slot(name: measurement.name, x: x, width: measurement.width))
            x += measurement.width
        }

        self.slots = slots
        self.rules = rules
        self.width = x
    }

    /// The module a press at `x` belongs to.
    ///
    /// The last slot beginning at or before the press, so a gap or a
    /// separator between two readings belongs to the one on its left, and a
    /// press past the right-hand end -- which happens, because the item is a
    /// point or two wider than the readings while a value is changing --
    /// still opens the module it is nearest. A press on an empty row is the
    /// only nil: there is nothing to open.
    func slot(atX x: CGFloat) -> Slot? {
        slots.last { $0.x <= x } ?? slots.first
    }

    /// `CombinedModules_spacing` has held two kinds of value.
    ///
    /// Kit's settings window wrote the numbers 1...8. Roost's writes names.
    /// Both are read here, because a Mac that has been running Roost has
    /// whichever its version of Settings stored -- and because the named
    /// values parsed as no number at all, which is why choosing Small,
    /// Normal or Large has been doing nothing since Settings was rebuilt.
    static func spacing(named name: String) -> CGFloat {
        if let points = Int(name) { return CGFloat(min(max(points, 0), 8)) }
        switch name {
        case "small":  return 2
        case "normal": return 4
        case "large":  return 8
        default:       return 0     // "none", and anything unrecognised
        }
    }
}
