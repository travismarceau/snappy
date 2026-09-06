# Snappy

Divvy-style window placement for macOS. Press one leader key, a grid appears over
your screen, press one more key and the front window lands in the region you drew
for it.

Snappy is derived from [Rectangle](https://github.com/rxhanson/Rectangle) by Ryan
Hanson (MIT), which is itself based on Spectacle by Eric Czarny. The window-moving
engine is Rectangle's; the leader-key grid, drawn placement regions, and
multi-window layouts are Snappy's own.

## System requirements

macOS 10.15 or later.

## Installation

Download the latest build from <https://getsnappy.fyi/>, or build from source:

```bash
git clone https://github.com/travismarceau/snappy.git
cd snappy
./scripts/build-direct.sh     # notarized release; needs a Developer ID certificate
```

For a local build, open `Snappy.xcodeproj` and run the `Snappy` scheme.

Snappy needs Accessibility permission to move other apps' windows, and asks for
it on first launch. It cannot be sandboxed: the App Sandbox denies the mach
lookup of `com.apple.axserver`, so a sandboxed build reports the permission as
granted and then silently does nothing. See [docs/APP_STORE.md](docs/APP_STORE.md).

## How it works

### Placements

A placement is a region of a grid bound to a single key.

1. Open **Settings ▸ Placements** and set your grid — 6×6 by default.
2. Click **+**, drag a region on the grid, and press the key you want it on.
3. Anywhere in macOS, press the leader shortcut (⌃⌥Space by default), then that
   key. The frontmost window moves to the region.

Press the leader key again, or Escape, to dismiss without moving anything. An
unrecognised key reveals the full map rather than doing nothing.

### Layouts

A layout arranges several windows at once. Under **Settings ▸ Layouts**, bind a
key, then add one window per app and draw where each goes. One keystroke in the
overlay places them all. Apps that aren't running, or are running with no open
window, are named on screen rather than silently skipped.

### Snap areas

Drag a window to a screen edge and release. The footprint shows where it will
land.

| Snap area                                              | Resulting action                       |
|--------------------------------------------------------|----------------------------------------|
| Left or right edge                                     | Left or right half                     |
| Top                                                    | Maximize                               |
| Corners                                                | Quarter in respective corner           |
| Left or right edge, just above or below a corner       | Top or bottom half                     |
| Bottom left, center, or right third                    | Respective third                       |
| Bottom left or right third, then drag to bottom center | First or last two thirds, respectively |

### Ignore an app

While an ignored app is frontmost, Snappy un-registers its shortcuts from macOS,
which is useful when an app has shortcuts of its own that clash. Focus the app,
open the Snappy menu, and select "Ignore app". Repeat to un-ignore.

## Execute an action by URL

Open `snappy://execute-action?name=[name]`, ideally without activating Snappy.

```bash
open -g "snappy://execute-action?name=left-half"
```

Available names: `left-half`, `right-half`, `center-half`, `top-half`,
`bottom-half`, `top-left`, `top-right`, `bottom-left`, `bottom-right`,
`first-third`, `center-third`, `last-third`, `first-two-thirds`,
`last-two-thirds`, `maximize`, `almost-maximize`, `maximize-height`, `smaller`,
`larger`, `center`, `center-prominently`, `restore`, `next-display`,
`previous-display`, `move-left`, `move-right`, `move-up`, `move-down`,
`first-fourth`, `second-fourth`, `third-fourth`, `last-fourth`,
`first-three-fourths`, `last-three-fourths`, `top-left-sixth`,
`top-center-sixth`, `top-right-sixth`, `bottom-left-sixth`,
`bottom-center-sixth`, `bottom-right-sixth`, `specified`, `reverse-all`,
`tile-all`, `cascade-all`, `cascade-active-app`, plus the ninth, third, and
eighth variants.

Apps can be ignored by URL too:

```
snappy://execute-task?name=ignore-app
snappy://execute-task?name=unignore-app
snappy://execute-task?name=ignore-app&app-bundle-id=com.apple.Safari
```

## Hidden preferences

See [TerminalCommands.md](TerminalCommands.md).

## Troubleshooting

If windows aren't moving as expected, most causes turn out to be other apps or a
stale Accessibility grant.

1. Lock and unlock your Mac. This resolves a surprising number of cases,
   especially after a system update.
2. Make sure macOS is up to date, and restart if you've just updated.
3. Re-grant Accessibility: System Settings ▸ Privacy & Security ▸ Accessibility,
   remove Snappy, then add it back.
4. Enable debug logging — hold Option and choose "View Logging…" from the Snappy
   menu — to see what Snappy thinks it is doing.

### Window resizing is off slightly for iTerm2

iTerm2 resizes in increments of character widths by default:

```bash
defaults write com.googlecode.iterm2 DisableWindowSizeSnap -integer 1
```

### Notification Center freezes

Affects a small number of users. Uncheck "Snap windows by dragging" in Settings.
See Rectangle issue [317](https://github.com/rxhanson/Rectangle/issues/317).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. Snappy is a derivative work of Rectangle; see [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md) for full attribution.
