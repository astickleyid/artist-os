# Running Artist OS on your machines

Everything here is one command. You never touch Xcode's UI unless you're
running on your physical iPhone (which needs your Apple ID once).

## Prereqs (one time)
- **Xcode** from the App Store (Swift toolchain + iOS Simulator).
- **Homebrew** (https://brew.sh) — scripts auto-install `xcodegen`.

Open Terminal, `cd` into the project folder, then run `./scripts/preflight.sh`
once — it checks everything and tells you in plain English how to fix anything
missing.

## Demo on your iPhone (physical device)
```
make device
```
Generates the project and opens it in Xcode. Then, one time only:
1. Select the **ArtistOSMobile** target → **Signing & Capabilities**.
2. Check **Automatically manage signing** → pick your **Team** (your Apple ID).
3. Plug in your iPhone, choose it as the destination (top bar), press **▶**.

That Apple-ID step is the one thing only you can do — it's your developer
identity signing the app onto your own phone. You're already enrolled, so it's
about 30 seconds the first time, then never again.

## macOS app (runs locally, no signing)
```
make mac
```
Builds `build/ArtistOS.app` and opens it. First launch, macOS may say
"unidentified developer" → right-click → **Open** (or once:
`xattr -dr com.apple.quarantine build/ArtistOS.app`).

## iOS in the Simulator (no device, no signing)
```
make ios
```
Auto-picks an installed simulator, builds, installs, launches. Override with
`SIM_DEVICE="iPhone 15" make ios`.

## Tests
```
make test
```

## Prefer not to build locally? Grab CI artifacts
Repo → **Actions** → latest green run → download **ArtistOS-macOS-app** (unzip,
double-click) or **ArtistOS-iOS-simulator-app** (unzip, drag onto a booted
Simulator). Note: the iOS artifact is a *Simulator* build — for your physical
phone use `make device` above.
