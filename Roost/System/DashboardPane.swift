import AppKit
import SwiftUI

/// The Dashboard page, as the AppKit view the settings window swaps in.
///
/// The page itself is `DashboardView`; this hosts it and decides when it is
/// live. The settings window shows a page by putting its view in the detail
/// pane and takes it out again for the next one, so being in a window is
/// exactly being on screen -- and the model listens to the menu bar tick only
/// then. The page it replaced started a timer when shown and never stopped
/// it, because nothing told it that it had been taken off screen.
final class DashboardPane: NSView {

    private let model: DashboardModel

    init(open: @escaping (String) -> Void, enable: @escaping (String) -> Void) {
        self.model = DashboardModel(open: open, enable: enable)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(rootView: DashboardView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        // The window owns the size; the page scrolls inside whatever it is
        // given rather than asking for its own ideal height.
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called by the window as the page is shown, so the first frame has
    /// this second's readings rather than whatever was true when it was
    /// last on screen.
    func viewWillAppear() { model.refresh() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        model.isActive = window != nil
    }
}
