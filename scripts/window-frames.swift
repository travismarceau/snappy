#!/usr/bin/env swift

/// window-frames.swift
///
/// Dumps on-screen window geometry as JSON. Used by `verify-sandbox.sh` to
/// prove the sandboxed build actually moved another app's window, and by
/// `capture-screenshots.sh` to resolve a window id for `screencapture -l`.
///
/// It reads only `kCGWindowNumber`, `kCGWindowLayer`, `kCGWindowBounds`,
/// `kCGWindowOwnerPID` and `kCGWindowOwnerName` — none of which are gated by
/// Screen Recording (only `kCGWindowName`, the title, is, and it is never
/// read). So this script needs no TCC permission of its own, which is the
/// whole point: the observer must not depend on the grant being tested.
///
/// Deliberately standalone rather than importing anything from the app, so a
/// bug in Snappy cannot make its own verification pass.
///
///   swift scripts/window-frames.swift                    # every normal window
///   swift scripts/window-frames.swift --owner TextEdit   # just TextEdit's
///   swift scripts/window-frames.swift --owner Snappy --all-layers
///   swift scripts/window-frames.swift --owner TextEdit --id-only

import CoreGraphics
import Foundation

var ownerFilter: String?
var allLayers = false
var idOnly = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--owner":
        guard let value = args.first else {
            FileHandle.standardError.write(Data("--owner needs a value\n".utf8))
            exit(2)
        }
        args.removeFirst()
        ownerFilter = value
    case "--all-layers":
        allLayers = true
    case "--id-only":
        idOnly = true
    case "-h", "--help":
        print("usage: window-frames.swift [--owner NAME] [--all-layers] [--id-only]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
        exit(2)
    }
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("CGWindowListCopyWindowInfo returned nothing\n".utf8))
    exit(1)
}

struct Window {
    let id: Int
    let pid: Int
    let layer: Int
    let owner: String
    let x: Int, y: Int, width: Int, height: Int
}

var windows: [Window] = []

for info in raw {
    guard
        let id = info[kCGWindowNumber as String] as? Int,
        let pid = info[kCGWindowOwnerPID as String] as? Int,
        let layer = info[kCGWindowLayer as String] as? Int,
        let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { continue }

    // Layer 0 is a normal application window. Menus, the status bar, and the
    // placement overlay itself sit above it; skipping them keeps the before/
    // after diff about the window we actually asked Snappy to move.
    if !allLayers && layer != 0 { continue }

    let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
    if let filter = ownerFilter, !owner.localizedCaseInsensitiveContains(filter) { continue }

    // Zero-size windows are offscreen scratch surfaces, never anything a user
    // would recognise as "the window".
    if bounds.width < 1 || bounds.height < 1 { continue }

    windows.append(Window(id: id, pid: pid, layer: layer, owner: owner,
                          x: Int(bounds.origin.x), y: Int(bounds.origin.y),
                          width: Int(bounds.width), height: Int(bounds.height)))
}

// Front-to-back is the order CGWindowList returns; largest-first is more useful
// for "the" window of an app, since a document window outranks its inspectors.
windows.sort { ($0.width * $0.height) > ($1.width * $1.height) }

if idOnly {
    guard let first = windows.first else { exit(1) }
    print(first.id)
    exit(0)
}

let objects: [[String: Any]] = windows.map {
    ["id": $0.id, "pid": $0.pid, "layer": $0.layer, "owner": $0.owner,
     "x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height]
}

let data = try JSONSerialization.data(withJSONObject: objects,
                                      options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
