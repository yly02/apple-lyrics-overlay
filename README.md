# Apple Music Desktop Lyrics Overlay

A lightweight macOS menu bar app that brings Apple Music lyrics onto the desktop in a clean floating overlay.

![Apple Music Lyrics Overlay screenshot](docs/overlay-screenshot.png)

## What it does

- Shows the current lyric line in a desktop overlay that stays above normal windows
- Shows Simplified Chinese translation for non-Chinese lyrics
- Falls back across multiple lyric sources to improve coverage
- Keeps credentials local and out of the repository
- Lets you adjust font, color, width, animation, lock state, and appearance from the menu bar

## Highlights

- `Real-time sync` Reads the current Apple Music track and playback position through AppleScript
- `Translation pipeline` Supports built-in translation flow, Tencent API configuration, retries, timeout fallback, and local caches
- `Desktop-first UI` Floating lyric overlay with blur styling, menu bar controls, and remembered window position
- `Safer storage` Translation credentials live in the local Keychain/Application Support, not in Git
- `Double-click launch` Can be built into a standalone `.app` bundle for everyday use

## Requirements

- macOS 15.0 or later
- Apple Music app
- Swift 6.3 / Xcode toolchain with Swift Package Manager

## Run locally

```bash
./run-overlay.sh
```

## Build the app bundle

```bash
./build-app.sh
```

By default this creates:

```text
~/Desktop/Apple Music Lyrics.app
```

## Main features

- `Lyrics overlay`
  - Shows the current line on the desktop
  - Supports translation line display for English, Japanese, Korean, and other non-Chinese lyrics
  - Can show song title and artist while switching tracks

- `Customization`
  - Lyric size presets
  - Custom font selection
  - Base color and gradient color via the macOS color picker
  - Light, dark, or follow-system appearance
  - Multiple lyric animation modes
  - Lock and unlock overlay position

- `Stability work`
  - Prefetches translations to reduce visible lag
  - Retries failed translation requests once
  - Uses timeout downgrade so one slow line does not block the whole overlay
  - Remembers the last window position, including multi-display handling

- `Fallbacks`
  - LRCLIB
  - Apple Music local lyrics field
  - lyrics.ovh plain-text fallback
  - Persistent local caches for lyrics and translation results

## Privacy and security

- No API keys or secrets are committed in this repository
- Translation credentials are stored locally in:
  - macOS Keychain
  - the user's Application Support directory
- Build output, app bundles, `.env` files, and Swift build artifacts are ignored by Git

## Project structure

```text
Sources/apple-lyrics-overlay/apple_lyrics_overlay.swift   Main app implementation
Resources/                                                App resources
Tests/apple-lyrics-overlayTests/                          Package tests
build-app.sh                                              Build standalone app bundle
run-overlay.sh                                            Run in development mode
```

## Notes

- Some songs may still have no synced lyrics, depending on source availability
- When translation is unavailable, the app keeps the original lyric instead of showing an error banner
- Apple Music permissions may be required the first time the app reads playback state

## License

MIT. See [LICENSE](LICENSE).
