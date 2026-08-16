<p align="center">
  <img src="Design/app-icon-source.png" alt="YTGrab app icon" width="180">
</p>

<h1 align="center">YTGrab</h1>

<p align="center">
  A native macOS utility for downloading YouTube videos as edit-ready MP4 files.
</p>

<p align="center">
  <img alt="Version 1.2" src="https://img.shields.io/badge/version-1.2-EA3318">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-16171B?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-required-16171B">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-F7551F">
</p>

YTGrab is a CRIT Studio product. It downloads a YouTube video and hands you an
MP4 you can drop straight onto a Premiere timeline. Encoding runs on the
M-series media engine through VideoToolbox, so a 4K transcode finishes at
roughly playback speed.

## Install the app

1. Download `YTGrab-1.2-Apple-Silicon.dmg` from the [latest release](../../releases/latest).
2. Open the DMG and drag **YTGrab** into **Applications**.
3. Open YTGrab from the Applications folder.

> [!NOTE]
> The current build is signed for local use and is not notarized for public
> distribution. If macOS shows a security warning, Control-click YTGrab,
> choose **Open**, and confirm once.

## Open and run

```bash
open YTGrab.xcodeproj
```

Press Run. Nothing else to install, configure or resolve. YTGrab embeds
`yt-dlp`, `ffmpeg`, `ffprobe` and Deno inside the app. On first use it copies
them to its private Application Support folder, where the update command can
replace the fast-moving network tools without modifying the signed app.

The app is ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`) so it builds without a
developer account. If you have a team, set it in Signing & Capabilities and
the app will sign properly.

This bundle targets Apple Silicon and macOS 14. Drop the deployment target to 13 if you need to,
but you will have to replace the two-parameter `onChange` calls in
`ContentView.swift` with the older single-parameter form.

## Embedded tools and updates

The app menu has **Check for Tool Updates…**. It fetches the latest official
GitHub releases of yt-dlp and Deno, requires the release API's SHA-256 digest,
validates each tool by launching it, and only then replaces the managed copy.
FFmpeg stays pinned to the version tested with the app; update it with a new app
release so encoder behavior cannot change unexpectedly underneath a job.

`YTGrab.entitlements` keeps the App Sandbox off because the app intentionally
launches and updates executable tools in Application Support. Hardened runtime
is also off for this local build. A public/notarized release should use a real
Developer ID workflow and re-test child-process signing before distribution.

The official yt-dlp executable includes its current EJS solver; Deno is passed
explicitly as its JavaScript runtime. This matters for current YouTube format
availability and avoids another hidden system dependency.

## Third-party licenses

Embedding the tools makes their notices part of the distribution. The app's
Help menu includes **Embedded Tools & Licenses**, and the source notices live
under `YTGrab/Licenses`.

- yt-dlp: The Unlicense
- Deno: MIT
- the bundled FFmpeg/FFprobe build: GNU GPL v3 or later

The exact FFmpeg build configuration, GPL text, upstream source URL and open
build-script URL are included. Review the obligations for your distribution
model before publishing the app; the source project does not turn third-party
code into CRIT Studio property.

## Branding

`Brand.swift` is the design system. Colours are sampled off the supplied mark
rather than eyeballed. Because the mark carries a gradient, the warm range is
kept as four stops instead of one flat red: `#A40A02` in the shadowed leg,
`#EA3318` across the body, `#F7551F` on the lit edge, `#FA7937` on the folded
corner. Surfaces come from the plate the mark sits on: `#0E0F12`, `#16171B`,
`#211F22`.

Nothing else in the app hardcodes a colour, so editing those constants
restyles the whole thing. Primary buttons use `Brand.accentFill`, a gradient
running on the same axis as the light in the mark, so the chrome and the icon
agree rather than merely sitting near each other.

The YTGrab icon source PNG lives in `Design/app-icon-source.png` for future
regeneration. The original CRIT studio mark is preserved separately in
`Design/CRIT-logo-source.png` and appears only in the compact About panel.

`BrandViews.swift` has the compact About panel. The main window uses the YTGrab
video/download icon, while the CRIT studio mark is deliberately confined to
About.

### Swapping the logo

```bash
./install-icon.sh ~/path/to/logo.png
```

Square PNG, 1024px or larger. It rebuilds all ten sizes macOS wants and
rewrites the asset manifest without changing the CRIT mark used by About. Clean
the build folder in Xcode afterwards, since the icon cache is stubborn.

## Files

`Models.swift` holds the presets and job description. Quality presets map to
VideoToolbox quality values and x264/x265 CRF numbers rather than fixed
bitrates, so a static interview stays small and a shaky handheld ride clip gets
the bits it needs.

`ToolLocator.swift` prepares and resolves the managed copies from Application
Support. Its child PATH begins with that private tools folder, so yt-dlp finds
the matching ffmpeg and Deno copies when the app is launched from Finder.

`ToolUpdateManager.swift` handles official release metadata, checksums,
validation and atomic replacement. `ToolUpdateView.swift` provides the update
and license window used by the app menu.

`ProcessRunner.swift` spawns the tools and streams their output. It splits on
carriage returns as well as newlines because ffmpeg updates progress in place,
and it reads the pipe before waiting on exit, otherwise a large yt-dlp JSON
payload fills the buffer and the child blocks forever.

`CommandBuilder.swift` decides what ffmpeg actually gets asked to do. All the
format selection and encoder flag logic lives here, separately from the
plumbing, so it is easy to adjust.

`DownloadEngine.swift` runs the job and publishes log lines and progress.

`ContentView.swift` is the interface.

## What it handles for you

HEVC output gets the `hvc1` tag. Without it QuickTime and Premiere refuse to
open the file at all, which is the usual reason a hand-rolled ffmpeg HEVC
export appears broken.

Colour primaries, transfer and matrix are copied from the source, so nothing
shifts on import.

YouTube audio arrives as Opus, which MP4 cannot carry, so it becomes AAC at
256k, or 320k for surround. AAC and MP3 sources are copied untouched.

If your ffmpeg build rejects constant-quality mode on VideoToolbox, which some
older ones do, the job retries at a resolution-appropriate bitrate instead of
failing.

Temp files go to a hidden folder inside your output directory, so the final
write stays on the same volume, and they get cleaned up whether the job
finishes, errors, or is cancelled.

## Using it

Paste a link, press Check. The app reads what that specific video actually
has and fills the Detected panel with it: top resolution, codec, frame rate,
HDR flag and running time. The quality menu then lists every real rung with
its own detail, so a line reads `2160p · 4K · VP9 · ~1.4 GB` rather than a
bare number. Nothing is assumed; if a video tops out at 1080p, 1080p is what
you are offered.

Under the menu, the app says the one thing that matters for the rung you
picked. Above 1080p YouTube only serves VP9 or AV1, so there is no H.264
stream to copy and a 4K grab always means transcoding. Choose Keep original at
a height where H.264 does exist and it tells you the copy will be clean.
Choose it where H.264 does not exist and it warns that Premiere will reject
the file.

For 4K, use Archive or High with the media engine. Software mode gets you
maybe ten percent smaller at the same visual quality, but it is much slower
and it runs on CPU cores rather than the dedicated block.

Keep yt-dlp current. YouTube changes things often and a stale copy is usually
why a download suddenly stops working. Use **YTGrab → Check for Tool Updates…**;
Terminal and Homebrew are not required.

## Responsible use

Download only content you own or have permission to save. You are responsible
for following applicable laws, copyright rules and the terms of service of the
websites you use.

## Copyright

Copyright © 2026 Kamalanarayanan, CRIT Studio. All rights reserved.
