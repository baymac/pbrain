# Plane desktop app (deep-linkable)

A small **Tauri v2** wrapper around the local Plane instance (`http://localhost:1800`)
that registers a `plane://` URL scheme, so clicking a Plane link from anywhere
(chat, terminal, Slack) opens that exact issue **inside the app** instead of a browser.

Replaces the old Pake build (`../build-plane-app.sh`), which could not deep-link
because Pake ignores any URL passed to it on launch.

## Why `plane://` and not the raw `http://` link

macOS only lets an app capture plain `http://` links by becoming the default
browser or via Apple universal links (an `apple-app-site-association` file served
over HTTPS) — neither works for a local `http://plane.localhost:1800` instance.
A **custom scheme** is the reliable, no-server route.

## Link format

```
plane://pb/browse/PB-110   ↔   http://localhost:1800/pb/browse/PB-110
```

Rule: strip `plane://`, prepend `http://localhost:1800/`. A host segment
(`localhost:1800` / `plane.localhost:1800`) after the scheme is tolerated and
stripped. See `src-tauri/src/lib.rs` → `plane_uri_to_http` (unit-tested).

## Opening a link

```bash
# Already a deep link:
open 'plane://pb/browse/PB-110'

# Convert a raw browser link and open it:
./plane-open.sh 'http://plane.localhost:1800/pb/browse/PB-110'
```

`plane-open.sh` accepts the raw `http://plane.localhost...` URL, the `localhost`
form, an existing `plane://` link, or a bare `pb/browse/PB-110` path.

**For pbrain:** commands that emit Plane links (groom / plan-my-work / project-manager)
can pipe through `plane-open.sh`, or emit `plane://pb/...` links directly so they're
clickable straight into the app.

## Rebuild & install

Requires `cargo`, `cargo tauri` (`cargo install tauri-cli --version "^2"`), and a
running local Plane (Docker containers up).

```bash
cd src-tauri && cargo test --lib          # verify URL mapping
cd .. && cargo tauri build --bundles app  # ~1 min
# install (MANDATORY to /Applications — macOS only registers the scheme from there):
osascript -e 'quit app "Plane"' 2>/dev/null
rm -rf /Applications/Plane.app
cp -R src-tauri/target/release/bundle/macos/Plane.app /Applications/
xattr -dr com.apple.quarantine /Applications/Plane.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Plane.app
open -a Plane
```

## Notes

- First run shows Plane's **login** screen (fresh webview, no session). After you
  sign in, deep links land on the requested issue.
- The app only works while the Plane Docker containers are running.
- Bundle id: `com.plane.desktop`. Window: 1400×900, centered, overlay title bar.
- The `Cmd+Shift+P` global hotkey from the old Pake build is **not** ported.
