# Running Artist OS on your machines

Everything here is one command. You never touch Xcode's UI unless you want to.

## Prereqs (one time)
- **Xcode** installed from the App Store (gives you the Swift toolchain + iOS Simulator).
- **Homebrew** (https://brew.sh) — the iOS script uses it to install `xcodegen` automatically.

Open Terminal, `cd` into the project folder once, then:

## macOS app
```
make mac
```
Builds `build/ArtistOS.app` and opens it. Because it isn't code-signed yet, macOS
may say "unidentified developer" the first time — right-click the app → **Open**,
or run `xattr -dr com.apple.quarantine build/ArtistOS.app` once.

## iOS app (Simulator)
```
make ios
```
Generates the Xcode project, boots the iPhone Simulator, builds, installs, and
launches the companion. To target a different simulator: `SIM_DEVICE="iPhone 15" make ios`.

## Run the tests
```
make test
```

## Don't want to build locally? Grab the CI artifacts
Every push builds both apps on GitHub's Mac runners and attaches them:
1. Go to the repo → **Actions** → the latest green run.
2. Download **ArtistOS-macOS-app** (unzip → double-click) or
   **ArtistOS-iOS-simulator-app** (unzip → drag onto a booted Simulator, or
   `xcrun simctl install booted ArtistOSMobile.app`).

## Onto your real iPhone / TestFlight (later, needs your Apple ID)
The Simulator build is unsigned. For your physical phone or TestFlight we sign
with your Developer account — that's the one step that needs you, and I'll hand
you the exact flow when we get there. You're already enrolled, so it's short.
