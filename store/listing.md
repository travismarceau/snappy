# App Store Connect — copy for Snappy 1.0

Paste these into the corresponding fields. Character limits noted.

---

## Name  *(30 char max — must be globally unique)*

```
Snappy
```

⚠️ If "Snappy" is taken, use one of:

```
Snappy: Window Layouts
Snappy Window Manager
```

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
https://www.getsnappy.fyi/#support
```

## Marketing URL  *(optional)*

```
https://www.getsnappy.fyi/
```

## Privacy Policy URL  *(required)*

```
https://www.getsnappy.fyi/#privacy
```

> Use the `www.` host — it has a valid certificate and serves the page today.
> The bare apex `getsnappy.fyi` has a Porkbun ALIAS record pointing at the same
> target, but Porkbun's ALIAS flattening is not resolving it (it still returns
> Porkbun's parking IPs). Fixing the apex means pointing the domain's
> nameservers at DigitalOcean (`ns1/ns2/ns3.digitalocean.com`) so DO manages the
> apex directly — optional; `www.` is enough for the listing.

## Copyright

```
© 2026 Travis Marceau
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

`store/site.html` is live at **https://www.getsnappy.fyi/** (and, once DNS
finishes propagating, `https://getsnappy.fyi/`).

Setup, for the record:

- Source: GitHub repo `travismarceau/getsnappy-site` (public), `index.html` is a
  copy of `store/site.html`. Push to `main` to redeploy.
- Host: DigitalOcean App Platform static site, app `getsnappy`
  (ID `3229cad9-40e1-4641-8910-8c768902710d`), free tier, region NYC. Default
  ingress `https://getsnappy-gztct.ondigitalocean.app`.
- DNS: Porkbun. `www` → CNAME → `getsnappy-gztct.ondigitalocean.app` (live, valid
  cert). Apex `getsnappy.fyi` → ALIAS → same target (propagating).
- To edit the page: change `store/site.html`, copy it to the site repo's
  `index.html`, commit and push both.
