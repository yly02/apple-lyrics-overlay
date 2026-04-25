# Apple Music Desktop Lyrics Overlay

This is a lightweight macOS overlay for Apple Music that shows two rows of lyrics in a floating desktop window.

- Top row: current lyric line
- Bottom row: simplified Chinese translation when the current line is not already Chinese

How it works:

- Reads the current Apple Music track and playback position through AppleScript.
- Fetches synced lyrics through a pluggable lyric-source layer. The current provider is LRCLIB, with normalized title/artist matching to make future providers easier to add.
- Uses a configurable translation pipeline for Simplified Chinese output, with local caching and fallback providers.

Run it:

```bash
./run-overlay.sh
```

Build a double-clickable app bundle on your Desktop:

```bash
./build-app.sh
```

Notes:

- Drag the overlay window to reposition it.
- The app bundle is created at `~/Desktop/Apple Music Lyrics.app`.
- The app lives in the menu bar and can show or hide the lyrics window.
- You can change the lyric bar size from the menu bar under `歌词大小`.
- You can choose a custom lyric font from the menu bar under `歌词字体`.
- You can customize lyric base color and gradient color from the menu bar under `歌词颜色`, using the macOS color picker.
- You can lock or unlock the overlay position from the menu bar under `固定歌词位置`.
- Translation API credentials are stored locally in the user's Keychain/Application Support, not in this repository.
- The window stays above normal desktop windows.
- Some songs may not have synced lyrics available from LRCLIB.
- If a translation provider is unavailable or a line is unsupported, the app simply keeps the original line instead of showing an error banner.
