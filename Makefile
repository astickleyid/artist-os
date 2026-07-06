.PHONY: mac ios test app-mac clean

## Build + run the macOS app
mac:
	./scripts/run-mac.sh

## Build + run the iOS app in the Simulator
ios:
	./scripts/run-ios.sh

## Run the full Swift + Core test suite
test:
	swift test

## Package the macOS .app without launching (release)
app-mac:
	./scripts/package-macos-app.sh release

clean:
	rm -rf build apps/ios/build apps/ios/ArtistOS.xcodeproj .build
