/// SettingsTabViewController.swift
///
/// The settings window sizes itself to whichever pane is showing, and each pane
/// had been laid out to its own natural width — 500pt for General, 674pt for
/// Snap Areas, 760pt for Placement — so switching tabs made the window jump.
/// Pinning every pane to the widest one keeps a single width. The two narrower
/// panes centre their content inside a stack view pinned to the pane's edges,
/// so they gain margin rather than stretching.

import Cocoa

class SettingsTabViewController: NSTabViewController {

    /// The width of every settings pane, set by the widest of them (Placement).
    static let paneWidth: CGFloat = 760

    private static let widthConstraintIdentifier = "settingsPaneWidth"

    override func viewWillAppear() {
        super.viewWillAppear()
        // `willSelect` fires for later switches; the pane showing on open needs
        // pinning here, before the window sizes itself to it.
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            pinWidth(of: tabViewItems[selectedTabViewItemIndex].viewController?.view)
        }
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        // Reading `view` loads the pane, which is what we want: the constraint
        // has to exist before the tab controller measures it.
        pinWidth(of: tabViewItem?.viewController?.view)
        super.tabView(tabView, willSelect: tabViewItem)
    }

    private func pinWidth(of view: NSView?) {
        guard let view,
              !view.constraints.contains(where: { $0.identifier == Self.widthConstraintIdentifier })
        else { return }

        let width = view.widthAnchor.constraint(equalToConstant: Self.paneWidth)
        width.identifier = Self.widthConstraintIdentifier
        width.isActive = true
    }
}
