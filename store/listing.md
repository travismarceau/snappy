# App Store Connect — copy for Snappy 1.0

Paste these into the corresponding fields. Character limits noted.

---

## Name  *(30 char max — must be globally unique)*

```
Snappy Window Manager
```

21 characters. The app itself is still **Snappy** — `CFBundleName`, the Dock and
menu-bar name, the icon, and getsnappy.fyi are all unchanged. Apple permits a
store name that extends the bundle name, and the suffix earns two real search
keywords.

> **Why not just "Snappy"?** It's taken. There is a live iOS app named exactly
> `Snappy` (Delisa srl). App Store Connect enforces app-record name uniqueness
> across the *entire* store, not per-platform, so the record can't be created
> under that name even though the Mac App Store itself is clear — the only near
> matches there are *Snappy by Povio* and *Snappy - Screenshots*, neither of
> which is an exact collision.
>
> Checked 2026-09-03 via the iTunes Search API. `Snappy Window Manager` and
> `Snappy: Window Layouts` both came back unused; the first was chosen.

## Subtitle  *(30 char max)*

```
Keyboard window placement
```

## Promotional Text  *(170 char max — editable any time without review)*

```
Press one shortcut, then one key. Your window snaps to a region you drew on a grid. Save whole multi-window layouts to a single keystroke.
```

## Description  *(4000 char max)*

```
Snappy moves windows with the keyboard. Press one shortcut to open a grid over your screen, then press a single key — the front window jumps to the region you assigned that key. No chords, no dragging.

You define the regions. Draw any rectangle on a grid (halves, thirds, sixths, a lopsided two-thirds, whatever fits your screen) and bind it to a key. Build up as many as you want — a few, or a full keyboard's worth.

MULTI-WINDOW LAYOUTS
Bind a key to a set of apps and regions, and one press arranges them all at once. Editor left, terminal bottom-right, notes top-right — your whole working setup in a single keystroke.

THE OVERLAY
• A shortcut opens it; a single key places the window and it disappears.
• Pause and the full key-to-region map fades in, so you never have to remember.
• A "keep open" mode lets you place several windows in a row.
• Esc, or the shortcut again, dismisses it.

DETAILS
• Adjustable grid size, plus outer margins and gaps between windows.
• Send a placement to a specific display, or the next one.
• Drag-to-screen-edge snapping is included if you want it.
• Menu-bar app. No Dock icon, no account, no network.
• Import and export your configuration as JSON.

Snappy needs Accessibility permission to move windows — grant it once in System Settings and you're set.

Snappy's window-moving engine is derived from the open-source Rectangle project (MIT License); the leader-key grid, the drawn regions, and multi-window layouts are Snappy's own. Full attribution is in the app's About panel.
```

## Keywords  *(100 char max, comma-separated, no spaces after commas)*

Don't use other apps' names (Divvy, Rectangle, Magnet…) as keywords — Apple
rejects that.

```
window,manager,snap,tiling,layout,keyboard,shortcut,resize,arrange,grid,productivity,move
```

## Support URL  *(required)*

```
https://getsnappy.fyi/#support
```

## Marketing URL  *(optional)*

```
https://getsnappy.fyi/
```

## Privacy Policy URL  *(required)*

```
https://getsnappy.fyi/#privacy
```

> Both `getsnappy.fyi` and `www.getsnappy.fyi` serve the page over HTTPS with
> valid certs.

## Screenshots  *(at least 1, up to 10)*

App Store Connect accepts only **1280×800, 1440×900, 2560×1600 or 2880×1800**
for macOS — aspect 1.60. The built-in display is 3456×2234 (aspect 1.55), so a
raw capture is never a submittable size however it is cropped. Every frame is
therefore composed onto an exact 2880×1800 canvas.

Two steps:

```
./scripts/capture-screenshots.sh      # guided capture → store/screenshots/raw/
uv run design/compose_screenshots.py  # compose      → store/screenshots/*.png
```

Upload in this order — the first is the one that shows in search results:

| # | File | Caption |
|---|---|---|
| 1 | `01-overlay.png`    | One key. One region. |
| 2 | `02-placements.png` | Draw the regions you actually use. |
| 3 | `03-layouts.png`    | A whole arrangement in one keystroke. |
| 4 | `04-arranged.png`   | Editor, terminal, notes. One key. |
| 5 | `05-general.png`    | Grid size, margins, gaps. |
| 6 | `06-menubar.png`    | Lives in the menu bar. No account, no network. |

The ground is drawn from the app icon's palette (`design/render_icon.py`) — an
off-white-to-grey gradient ruled with the icon's own grid spacing, graphite
type. Each frame is the icon at another scale, with the app capture playing the
part of the placed window.

Before uploading, confirm every file is exactly 2880×1800:

```
sips -g pixelWidth -g pixelHeight store/screenshots/*.png
```

## Copyright

```
© 2026 Simarhol Onipaa LLC
```

## Category

- Primary: **Productivity**
- Secondary: **Utilities**

## Age Rating

Answer every question **None / No** → rating **4+**.

## App Privacy

- Data collection: **No, we do not collect data from this app.**

## Pricing

- Free (or pick a tier).

## Export Compliance

- `ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so App
  Store Connect won't prompt. If asked: **No**, the app does not use encryption
  beyond Apple's OS-level HTTPS/crypto (and it makes no network calls at all).

---

## App Review — Notes field

```
Snappy is a menu-bar window-placement utility. It requires macOS Accessibility permission to move windows:

1. Launch Snappy. Click the menu-bar icon.
2. If prompted, click "Open System Settings" and enable Snappy under Privacy & Security ▸ Accessibility. (Or add it manually with the + button.)
3. Press Control-Option-Space to open the placement grid. Press F for full screen, or add your own key→region bindings in Settings ▸ Placement.
4. Settings ▸ Placement ▸ Layouts lets you bind a key to a multi-app arrangement.

Originality / Guideline 4.1: Snappy's window-move engine is derived from the open-source Rectangle project (MIT License by Ryan Hanson), which is attributed in the app's About panel and the bundled LICENSE file, as the MIT license permits. Snappy's own design — a single leader shortcut that opens a grid overlay, user-drawn placement regions each bound to one key, and one-keystroke multi-window layouts — has no equivalent in Rectangle and is the reason the app exists. The preset chord shortcuts and shortcut-list UI that Rectangle ships have been removed.

No account, no network activity, no data collection.
```

---

## Hosting the Support / Privacy page — DONE

`store/site.html` is live at **https://getsnappy.fyi/** and
**https://www.getsnappy.fyi/**, both over HTTPS with valid certs.

Setup, for the record:

- Source: GitHub repo `travismarceau/getsnappy-site` (public), `index.html` is a
  copy of `store/site.html`. Push to `main` to redeploy.
- Host: DigitalOcean App Platform static site, app `getsnappy`
  (ID `3229cad9-40e1-4641-8910-8c768902710d`), free tier, region NYC. Default
  ingress `https://getsnappy-gztct.ondigitalocean.app`.
- DNS: Porkbun (nameservers stay at Porkbun). Both the apex `ALIAS` and the
  `www` `CNAME` point to `getsnappy-gztct.ondigitalocean.app`. The apex's
  default `ALIAS → pixie.porkbun.com` (Porkbun parking) had to be repointed —
  that was the cause of the earlier parking page.
- To edit the page: change `store/site.html`, copy it to the site repo's
  `index.html`, commit and push both.
