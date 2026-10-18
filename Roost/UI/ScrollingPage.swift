import AppKit

/// A settings page that scrolls when the window is shorter than it is.
///
/// Every module page and the Free up space page pin a column to their top
/// and leave its bottom free. In a window the height they were designed at,
/// that is fine; in one made shorter -- the window's minimum is 438pt, and
/// the Sensors page is three times that -- the bottom of the column was
/// simply cut off, with no scroller to say there was more. This wraps a page
/// as it is rather than rewriting seven of them: the page is made exactly as
/// tall as its content and put in a scroll view that opens at the top.
final class ScrollingPage: NSView {

    /// The page inside, for a caller that needs to talk to it.
    let page: NSView

    init(_ page: NSView) {
        self.page = page
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = TopFirst()
        document.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(page)

        // Centred, and no wider than `maxContentWidth`: a page pinned to
        // both edges of a wide window put every switch a thousand points
        // from its label.
        //
        // This only works because the hosted view above is told to fill the
        // pane. Without that, SwiftUI sizes it to this page's fitting size,
        // the backdrop shrinks with it, and the desktop shows through
        // beside the content -- which is exactly what happened the first
        // time this constraint was added.
        let fillsWidth = page.widthAnchor.constraint(equalTo: document.widthAnchor)
        fillsWidth.priority = .defaultHigh

        var constraints = [
            page.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            page.widthAnchor.constraint(lessThanOrEqualToConstant: RoostMetrics.maxContentWidth),
            page.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor),
            page.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            fillsWidth,
            // Raised by the title-bar clearance the page reserves and does
            // not need here -- see `RoostMetrics.pageTop`. What goes out of
            // view is that empty inset, never a row: every wrapped page
            // starts its column exactly `pageTop` down.
            page.topAnchor.constraint(equalTo: document.topAnchor,
                                      constant: RoostMetrics.contentTop - RoostMetrics.pageTop),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // At least the visible height, so a short page still fills the
            // pane instead of floating in it.
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        ]
        // The pages' columns hang from the top with nothing below them; this
        // is what gives the page a height of its own. Each subview, not just
        // the first, because a page is free to add a second.
        for content in page.subviews {
            constraints.append(page.bottomAnchor.constraint(
                greaterThanOrEqualTo: content.bottomAnchor, constant: RoostMetrics.pageInset))
        }
        // And otherwise as short as that allows -- without this the page
        // could be any height above its content, and the layout engine is
        // free to pick a tall one.
        let shortest = page.heightAnchor.constraint(equalToConstant: 0)
        shortest.priority = .defaultLow
        constraints.append(shortest)

        scroll.documentView = document
        addSubview(scroll)
        constraints += [
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Flipped, so the scroll view opens at the top of the page rather than at
/// its end -- the trap `GeneralPane`'s comment records falling into.
private final class TopFirst: NSView {
    override var isFlipped: Bool { true }
}
