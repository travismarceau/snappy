import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift set-dmg-icon.swift Snappy.app image.dmg\n", stderr)
    exit(1)
}

let appPath = CommandLine.arguments[1]
let imagePath = CommandLine.arguments[2]
let appURL = URL(fileURLWithPath: appPath)
guard let iconName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
    fputs("Could not find the app icon name: \(appPath)\n", stderr)
    exit(1)
}
let iconFile = iconName.hasSuffix(".icns") ? iconName : "\(iconName).icns"
let iconURL = appURL.appendingPathComponent("Contents/Resources/\(iconFile)")
guard let icon = NSImage(contentsOf: iconURL),
      NSWorkspace.shared.setIcon(icon, forFile: imagePath, options: []) else {
    fputs("Could not set the DMG file icon: \(imagePath)\n", stderr)
    exit(1)
}
