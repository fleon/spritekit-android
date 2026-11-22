#!/bin/bash
#
# Builds the stand-in game's Source/ (Templates/Check) for the iOS Simulator
# against Platform/ and Apple's own SpriteKit: the Apple side of the check
# Scripts/check-template.sh makes on Android. The same files compile on
# both, its view controller (StudioSplashScene.launch) and app delegate
# included, which Templates/Game's `exclude:` leaves out on Android.
#
#   Scripts/check-template-apple.sh
#
# The app's code is a package under .build/template-apple, as a game's
# Xcode target compiles it (Swift 5, main-actor isolation by default).
# Needs Xcode, and the checkout's folder named spritekit-android (Platform/
# reaches the runtime as `..`, by that name).

set -euo pipefail

runtime="$(cd "$(dirname "$0")/.." && pwd)"
package="$runtime/.build/template-apple"

echo "==> laying out the stand-in game's app code in $package"
rm -rf "$package/Sources"
mkdir -p "$package/Sources"
cp -R "$runtime/Templates/Check/Source" "$package/Sources/TemplateCheck"
cat > "$package/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TemplateCheck",
    platforms: [.iOS(.v15)],
    products: [.library(name: "TemplateCheck", targets: ["TemplateCheck"])],
    dependencies: [.package(path: "$runtime/Platform")],
    targets: [
        .target(
            name: "TemplateCheck",
            dependencies: [.product(name: "PlatformSprite", package: "Platform")],
            swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]
        ),
    ]
)
SWIFT

echo "==> building it for the iOS Simulator"
cd "$package"
xcodebuild build -scheme TemplateCheck -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$package/DerivedData" \
    -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO | tail -100
exit "${PIPESTATUS[0]}"
