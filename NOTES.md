# NOTES — my-version

Personal orientation notes for this fork. Paths are relative to the repo root.
Line numbers are approximate and drift as upstream changes.

## Quick SwiftUI primer (for a frontend dev)

- A `struct Foo: View` with a `var body` is a component; `body` is its render function.
- Modifiers (`.padding()`, `.frame()`, `.clipShape()`) are chained like CSS, but **order matters** — each one wraps the previous result.
- `@State` = local component state; `@ObservedObject` / `@EnvironmentObject` = shared store (like a context).
- `Defaults[.someKey]` = a persisted user preference (UserDefaults, think `localStorage`), via the [Defaults](https://github.com/sindresorhus/Defaults) package.
- `withAnimation(...) { state = x }` animates every view that depends on `state`. `.animation(anim, value: x)` animates when `x` changes.

## Folder structure

| Path | What it is |
|---|---|
| `boringNotch/` | The app's source code |
| `boringNotch/components/` | UI, grouped by feature (Notch, Music, Shelf, Calendar, Settings, Tabs, Webcam, Onboarding…) |
| `boringNotch/components/Notch/` | The notch window, shape, header and expanded home view |
| `boringNotch/sizing/matters.swift` | Notch sizes and corner radii |
| `boringNotch/models/` | View models (state) and `Constants.swift` (all settings keys) |
| `boringNotch/managers/` | Background services: music, battery, volume, brightness, calendar, webcam |
| `boringNotch/MediaControllers/` | One controller per music source (Now Playing, Apple Music, Spotify, YouTube Music) |
| `boringNotch/animations/` | Custom animations (hello animation, drop) |
| `boringNotch/Assets.xcassets` | Images, icons, colors |
| `boringNotch/Localizable.xcstrings` | Translations |
| `BoringNotchXPCHelper/` | Separate helper process (for privileged tasks like brightness/keyboard) |
| `mediaremote-adapter/` | Bundled framework + Perl script used to read "Now Playing" info |
| `updater/`, `Configuration/` | Sparkle auto-update feed and DMG packaging — not needed for local builds |
| `boringNotch.xcodeproj` | The Xcode project — open this in Xcode |

## Entry point and the notch window

- **Entry:** `boringNotch/boringNotchApp.swift` — `@main struct DynamicNotchApp` (~line 15) defines the menu-bar item. The real setup is in `AppDelegate.applicationDidFinishLaunching` (~line 282).
- **Window creation:** `createBoringNotchWindow(for:with:)` (~line 234) makes a borderless, non-activating panel (`BoringNotchSkyLightWindow`, in `components/Notch/BoringNotchSkyLightWindow.swift`) and puts `ContentView()` inside it via `NSHostingView` (the bridge from AppKit windows to SwiftUI).
- **Positioning:** `positionWindow(_:on:)` (~line 268) centers the window horizontally at the top of the screen. `adjustWindowPosition` (~line 477) re-runs this when displays change. One window per screen if "show on all displays" is on.
- **Window size** is fixed at the open size: `windowSize` in `sizing/matters.swift`. The notch shape animates *inside* that transparent window.

## Collapsed vs. expanded views

All in `boringNotch/ContentView.swift`:

- `body` (~line 83) — the outer black notch: shape, padding, shadow, hover handling.
- `NotchLayout()` (~line 246) — decides what's shown. Closed states: hello animation, battery/HUD "sneak peeks", `MusicLiveActivity()` (~line 389, album art + visualizer either side of the notch), `BoringFaceAnimation()`. Open state: `BoringHeader` + the current tab.
- Expanded content: `switch coordinator.currentView` (~line 347) → `NotchHomeView` (`components/Notch/NotchHomeView.swift`: music player, album art, controls, calendar, webcam) or `ShelfView` (`components/Shelf/Views/`).
- Notch outline: `components/Notch/NotchShape.swift` (the custom path with the inward-curving top corners).
- Header row in the open notch: `components/Notch/BoringHeader.swift`.

## Animations and hover/open behavior

- **Open/close springs:** `ContentView.swift` ~line 123–124 (`openAnimation`, `closeAnimation`). Shared hover spring: `animationSpring` ~line 41.
- **Content fade/scale when opening:** `.transition(...)` ~line 354.
- **Hover logic:** `handleHover(_:)` ~line 513 — waits `Defaults[.minimumHoverDuration]` then calls `doOpen()`; on leave, closes after 100 ms.
- **State:** `vm.open()` / `vm.close()` in `models/BoringViewModel.swift` (~line 192/200) flip `notchState`.
- **Sizes & corner radii:** `sizing/matters.swift` — `openNotchSize` (640×190), `cornerRadiusInsets`, album-art sizes.
- **Defaults** for hover: `models/Constants.swift` ~line 79–81 (`minimumHoverDuration` 0.3s, `openNotchOnHover`).

## How "Now Playing" works

1. `managers/MusicManager.swift` is the single store the UI reads (title, artist, artwork, isPlaying…). It picks a controller based on `Defaults[.mediaController]` (~line 121).
2. Controllers implement `MediaControllers/MediaControllerProtocol.swift`.
3. The default, `NowPlayingController.swift`, launches `/usr/bin/perl` with the bundled `mediaremote-adapter.pl` + `MediaRemoteAdapter.framework` (~line 191) and streams the system's Now Playing info. (Apple restricted direct access to the private MediaRemote API, hence the adapter.)
4. `AppleMusicController` / `SpotifyController` talk to those apps directly (AppleScript); YouTube Music has its own folder.

## Settings / preferences

- **Keys + defaults:** `models/Constants.swift` — `extension Defaults.Keys` (~line 71). Add a key here to add a setting.
- **Settings UI:** `components/Settings/SettingsView.swift` — one struct per tab: `GeneralSettings`, `Media`, `HUD`, `CalendarSettings`, `Shelf`, `Appearance` (~line 1160), `Advanced`, `Shortcuts`, `About`.
- **Window:** `components/Settings/SettingsWindowController.swift`.
- **Auto-updates:** `components/Settings/SoftwareUpdater.swift` (Sparkle). Turn auto-updates off in the app so the official release doesn't replace this build.

## 5 files most likely to edit for look & layout

1. `boringNotch/sizing/matters.swift` — open size, corner radii, album-art size.
2. `boringNotch/ContentView.swift` — notch container, animations, closed-state layout, shadow.
3. `boringNotch/components/Notch/NotchHomeView.swift` — expanded music player and home layout.
4. `boringNotch/components/Notch/NotchShape.swift` — the notch outline/curves.
5. `boringNotch/components/Notch/BoringHeader.swift` — top row of the open notch (tabs, icons).

Bonus: `models/Constants.swift` to change default setting values.

## Workflow

- Open `boringNotch.xcodeproj` in Xcode → ⌘R to build & run, ⌘. to stop.
- Signing: the project signs macOS builds ad-hoc (`CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`), so no Apple ID / team is needed to run locally.
- CLI build: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build` → app at `build/Build/Products/Debug/Boring Notch.app` (`build/` is git-ignored).
- Pull upstream updates: `git fetch upstream && git merge upstream/main` (on `my-version`).

## Claude questions in the island (my addition)

- `boringNotch/ClaudeBridge/` — `ClaudeBridgeServer.swift` (tiny HTTP server on `127.0.0.1:47823`), `ClaudeBridge.swift` (queue, timeouts, hook replies), `ClaudeQuestionView.swift` (the UI).
- `claude-bridge/dynamic-island-hook.sh` — Claude Code hook; `permission` for PermissionRequest (waits for an answer), `notify` for Notification.
- Opens on the display under the mouse (`claudeRequestChanged` in `boringNotchApp.swift`); stays open until answered (`BoringViewModel.close()`).
- Falls back to Claude's own prompt on "Answer in Claude", after 5 min, or if the app isn't running.
