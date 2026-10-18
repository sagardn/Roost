import CoreGraphics

/// Where a window goes when it is snapped -- the geometry, and nothing else.
///
/// Kept apart from the Accessibility calls that move a window so it can be
/// checked against numbers: every rule here is a rectangle computed from
/// another rectangle, and a wrong one puts a window half under the Dock.
///
/// Rectangles are in AppKit's screen coordinates throughout -- origin at the
/// bottom left of the primary display, y up -- because that is what
/// `NSScreen.visibleFrame` is in. Accessibility uses the other convention,
/// origin top left and y down; `appKit(fromAX:)` and `ax(fromAppKit:)`
/// convert at the edge, and only there.
enum Snap {

    enum Action: String, CaseIterable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case maximize, center, restore
        case nextDisplay, previousDisplay
    }

    /// Widths a repeated half cycles through, the way Rectangle does: press
    /// ⌃⌥← on a window already in the left half and it takes two thirds,
    /// again and it takes one third, again and it is back to half.
    static let cycle: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Close enough to call two frames the same: windows round their own
    /// frames to whole points, and some refuse a size by a point or two.
    static let tolerance: CGFloat = 4

    static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The frame for `action` on a screen whose usable area is `visible`,
    /// given where the window is now. nil for the actions that are not a
    /// position on this screen (restore, and moving between displays).
    static func frame(for action: Action, in visible: CGRect, current: CGRect) -> CGRect? {
        let v = visible
        switch action {
        case .leftHalf:
            let f = nextFraction(current, in: v) { CGRect(x: v.minX, y: v.minY, width: v.width * $0, height: v.height) }
            return CGRect(x: v.minX, y: v.minY, width: (v.width * f).rounded(), height: v.height)
        case .rightHalf:
            let f = nextFraction(current, in: v) { CGRect(x: v.maxX - v.width * $0, y: v.minY, width: v.width * $0, height: v.height) }
            let width = (v.width * f).rounded()
            return CGRect(x: v.maxX - width, y: v.minY, width: width, height: v.height)
        case .topHalf:
            let f = nextFraction(current, in: v) { CGRect(x: v.minX, y: v.maxY - v.height * $0, width: v.width, height: v.height * $0) }
            let height = (v.height * f).rounded()
            return CGRect(x: v.minX, y: v.maxY - height, width: v.width, height: height)
        case .bottomHalf:
            let f = nextFraction(current, in: v) { CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height * $0) }
            return CGRect(x: v.minX, y: v.minY, width: v.width, height: (v.height * f).rounded())
        case .topLeft:
            return quarter(v, right: false, top: true)
        case .topRight:
            return quarter(v, right: true, top: true)
        case .bottomLeft:
            return quarter(v, right: false, top: false)
        case .bottomRight:
            return quarter(v, right: true, top: false)
        case .maximize:
            return v
        case .center:
            let width = min(current.width, v.width), height = min(current.height, v.height)
            return CGRect(x: (v.midX - width / 2).rounded(), y: (v.midY - height / 2).rounded(),
                          width: width, height: height)
        case .restore, .nextDisplay, .previousDisplay:
            return nil
        }
    }

    /// The next width or height in `cycle` if the window already sits at one
    /// of them, else a half.
    private static func nextFraction(_ current: CGRect, in visible: CGRect,
                                     _ shape: (CGFloat) -> CGRect) -> CGFloat {
        guard let at = cycle.firstIndex(where: { isClose(current, shape($0)) }) else { return cycle[0] }
        return cycle[(at + 1) % cycle.count]
    }

    private static func quarter(_ v: CGRect, right: Bool, top: Bool) -> CGRect {
        let width = (v.width / 2).rounded(), height = (v.height / 2).rounded()
        return CGRect(x: right ? v.maxX - width : v.minX, y: top ? v.maxY - height : v.minY,
                      width: width, height: height)
    }

    /// The same place on another screen: the window keeps its position and
    /// size as a share of the usable area, so a left half stays a left half
    /// and a small window in the corner stays small and in the corner.
    static func move(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let sx = target.width / source.width, sy = target.height / source.height
        // Scaled, then never larger than the target, then kept inside it.
        let width = min((frame.width * sx).rounded(), target.width)
        let height = min((frame.height * sy).rounded(), target.height)
        var x = target.minX + ((frame.minX - source.minX) * sx).rounded()
        var y = target.minY + ((frame.minY - source.minY) * sy).rounded()
        x = min(max(x, target.minX), target.maxX - width)
        y = min(max(y, target.minY), target.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The screen a window is on: the one holding its centre, else the one
    /// it overlaps most, else the first.
    static func screenIndex(for frame: CGRect, among screens: [CGRect]) -> Int? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = screens.firstIndex(where: { $0.contains(centre) }) { return hit }
        let overlaps = screens.map { $0.intersection(frame) }.map { $0.isNull ? 0 : $0.width * $0.height }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0
        else { return screens.isEmpty ? nil : 0 }
        return best
    }

    // MARK: Coordinates

    /// Accessibility's top-left frame to AppKit's bottom-left one. Both are
    /// measured against the primary display, whose height is the only number
    /// the conversion needs -- including for displays above or below it,
    /// which simply come out with negative or large coordinates.
    static func appKit(fromAX frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func ax(fromAppKit frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
