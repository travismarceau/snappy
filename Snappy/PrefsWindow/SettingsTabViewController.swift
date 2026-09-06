/// SettingsTabViewController.swift
///
/// The settings window sizes itself to whichever pane is showing, and each pane
/// had been laid out to its own natural width — 500pt for General, 674pt for
/// Snap Areas, 760pt for Placements, 800pt for Layouts — so switching tabs made
/// the window jump. Every pane now declares the same width. The narrower ones
/// centre their content inside a stack view pinned to the pane's edges, so they
/// gain margin rather than stretching.
///
/// Two ways in, because a pane that sets `preferredContentSize` has AppKit swap
/// out any width constraint on its view: those panes assert the width on their
/// content instead (see PlacementConfigViewController), and the rest are pinned
/// here.

import Cocoa

class SettingsTabViewController: NSTabViewController {

    /// The width of every settings pane, set by the widest of them (Layouts,
    /// whose two side-by-side cards will not compress below this).
    static let paneWidth: CGFloat = 800

    private static let widthConstraintIdentifier = "settingsPaneWidth"

    override func viewDidLoad() {
        super.viewDidLoad()
        // Every pane, not just the selected one: a pane reports its size to the
        // tab controller from its own viewWillAppear, which runs before this
        // controller sees the switch, so the constraint has to be in place
        // first. Reading `view` loads the pane, which is the point.
        for item in tabViewItems {
            pinWidth(of: item.viewController?.view)
        }

        let saved = Defaults.settingsSelectedTab.value
        if tabViewItems.indices.contains(saved) {
            selectedTabViewItemIndex = saved
        }
    }

    /// Reopen on the pane you left, the way System Settings does. Someone
    /// tuning a layout across several sittings lands back where they were.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            Defaults.settingsSelectedTab.value = selectedTabViewItemIndex
        }
    }

    /// Constrains a pane that lets the tab controller size it. A pane that sets
    /// its own `preferredContentSize` loses this constraint the moment it does,
    /// so it must assert `paneWidth` on its content instead.
    private func pinWidth(of view: NSView?) {
        guard let view,
              !view.constraints.contains(where: { $0.identifier == Self.widthConstraintIdentifier })
        else { return }

        let width = view.widthAnchor.constraint(equalToConstant: Self.paneWidth)
        width.identifier = Self.widthConstraintIdentifier
        width.isActive = true
    }
}
