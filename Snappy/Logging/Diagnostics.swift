/// Diagnostics.swift
///
/// A one-click bug report.
///
/// Everything here was learned the hard way. When placement mode does nothing,
/// the cause is almost never visible from the outside: a sandboxed build
/// reports Accessibility as granted and silently fails, Secure Input blocks
/// every keyboard tap while leaving the mouse working, and a stale TCC record
/// looks identical to a missing one. Each of those took hours to find by
/// guesswork. Each is one line here.
///
/// The report is deliberately about Snappy and the permissions it needs, and
/// nothing else: no window titles, no list of running applications, no file
/// paths beyond this app's own bundle. Someone pasting this into a public issue
/// should not be handing over a picture of their desktop.

import AppKit
import Carbon
import IOKit.hid

enum Diagnostics {

    static let issueURL = "https://github.com/travismarceau/snappy/issues/new"

    /// The report, as markdown, ready to paste into an issue.
    static func report() -> String {
        var out: [String] = []

        out.append("### Snappy")
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        out.append("- Version: \(version) (\(build))")
        out.append("- Bundle id: \(Bundle.main.bundleIdentifier ?? "?")")
        out.append("- Installed at: \(installationLocation)")
        out.append("- Sandboxed: \(isSandboxed ? "yes — placement cannot work" : "no")")

        out.append("")
        out.append("### System")
        out.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("- Architecture: \(machineArchitecture)")

        out.append("")
        out.append("### Permissions")
        out.append("- Accessibility trusted: \(AXIsProcessTrusted())")
        out.append("- Input Monitoring: \(inputMonitoringDescription)")
        let secure = IsSecureEventInputEnabled()
        if secure {
            let holder = PlacementModeController.secureInputHolderName() ?? "unknown"
            out.append("- **Secure Input: ON (reported owner: \(holder))** — no application can")
            out.append("  receive keys while this is set. Bound keys cannot work; dragging still can.")
        } else {
            out.append("- Secure Input: off")
        }

        out.append("")
        out.append("### Last placement session")
        let d = UserDefaults.standard
        if let at = d.object(forKey: "lastSessionAt") as? Date {
            out.append("- At: \(ISO8601DateFormatter().string(from: at))")
            out.append("- Event tap running: \(d.bool(forKey: "lastSessionEventTapRunning")), enabled: \(d.bool(forKey: "lastTapIsEnabled"))")
            out.append("- Tap callbacks: \(d.integer(forKey: "lastSessionTapCallbacks")), events seen: \(d.integer(forKey: "lastSessionTapEventsSeen")), swallowed: \(d.integer(forKey: "lastSessionTapEventsSwallowed"))")
            if d.bool(forKey: "lastSessionSecureInputEnabled") {
                out.append("- Secure Input was on during that session")
            }
        } else {
            out.append("- (placement mode has not been opened since this version launched)")
        }

        out.append("")
        out.append("### Settings")
        let map = Defaults.placementKeymap.typedValue ?? .empty
        out.append("- Placement mode: \(Defaults.placementModeEnabled.userEnabled ? "on" : "off")")
        out.append("- Drag to place: \(Defaults.placementDragEnabled.userDisabled ? "off" : "on")")
        out.append("- Grid: \(map.grid.cols)×\(map.grid.rows), margin \(Int(map.outerMargin)), gap \(Int(map.innerGap))")
        out.append("- Placements: \(map.assignedBindings.count), layouts: \(map.assignedLayouts.count)")
        if let leader = PlacementModeManager.shortcut(for: PlacementModeManager.defaultsKey) {
            out.append("- Leader shortcut: \([leader.modifierFlagsString, leader.keyCodeString].compactMap { $0 }.joined())")
        }

        out.append("")
        out.append("### What happened")
        out.append("<!-- What did you do, what did you expect, what happened instead? -->")

        return out.joined(separator: "\n")
    }

    /// Put the report on the pasteboard and tell the user it is there.
    static func copyToPasteboard() {
        let text = report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.log("Diagnostics copied to the pasteboard")
    }

    /// Open a prefilled issue. GitHub truncates very long query strings, so the
    /// report goes on the pasteboard too — if the prefill is clipped, the full
    /// text is one paste away rather than lost.
    static func openIssue() {
        let text = report()
        copyToPasteboard()
        var components = URLComponents(string: issueURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: issueTitle()),
            URLQueryItem(name: "body", value: text),
        ]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Facts

    /// True when this build runs in the App Sandbox, which denies the mach
    /// lookup of com.apple.axserver: Accessibility then reports as granted and
    /// nothing moves. Checked by container path because that is observable
    /// without parsing our own code signature.
    static var isSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Enough location detail to diagnose a translocated or uninstalled copy,
    /// without putting a username or private directory names into a public issue.
    static var installationLocation: String {
        installationLocation(for: Bundle.main.bundlePath,
                             home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func installationLocation(for path: String, home: String) -> String {
        if path.hasPrefix("/Applications/") { return "/Applications" }

        if path.hasPrefix(home + "/Applications/") { return "~/Applications" }
        if path.hasPrefix(home + "/") { return "inside the user’s home directory" }
        if path.hasPrefix("/Volumes/") { return "a mounted volume" }
        if path.contains("/AppTranslocation/") { return "an App Translocation location" }
        return "another system location"
    }

    static func issueTitle(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "[\(version) build \(build)] "
    }

    static var inputMonitoringDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied:  return "denied — keyboard events will not reach Snappy"
        default:                       return "not determined"
        }
    }

    static var machineArchitecture: String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "?" }
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
