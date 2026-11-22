#!/bin/bash
#
# Builds the game templates into a debug APK, around a stand-in game
# (Templates/Check): the check that a game made from Templates/Game and
# Templates/App/base still compiles, links and packages against the runtime.
#
#   Scripts/check-template.sh             # every ABI the app ships
#   Scripts/check-template.sh x86_64      # just one
#
# The game is laid out under .build/template-check as a game's repository
# is, the runtime copied in as its submodule (Vendor/ linked, not copied).
# Prints the APK's path last. Needs Vendor/build.sh android, JDK 17, the
# Android SDK and ~/.android/debug.keystore.

. "$(dirname "$0")/config.sh"
require_ndk
use_swiftly

abis=("$@")
[ ${#abis[@]} -eq 0 ] && abis=("${ABIS[@]}")

game="$RUNTIME_DIR/.build/template-check"
runtime="$game/Android/spritekit-android"
module="TemplateCheck"
package="com.example.templatecheck"

echo "==> laying out the stand-in game in $game"
mkdir -p "$runtime"
# The runtime as a submodule: its sources, not its builds. The game package's
# own .build survives between runs, so a second run is incremental.
rsync -a --delete --exclude /.git --exclude /.build --exclude /Vendor --exclude '.swiftpm' \
    "$RUNTIME_DIR/" "$runtime/"
ln -sfn "$VENDOR_DIR" "$runtime/Vendor"
rm -rf "$game/Source" "$game/Assets" "$game/Android/App" "$game/Android/Assets"
cp -R "$RUNTIME_DIR/Templates/Check/Source" "$game/Source"
mkdir -p "$game/Assets" "$game/Android/Game"
rsync -a --delete --exclude /.build "$RUNTIME_DIR/Templates/Game/" "$game/Android/Game/"
cp -R "$RUNTIME_DIR/Templates/App/base" "$game/Android/App"

# The placeholders, as Templates/Game/README.md and Templates/App/README.md
# list them.
mv "$game/Android/Game/Sources/GAME_MODULEEntry" "$game/Android/Game/Sources/${module}Entry"
java="$game/Android/App/app/src/main/java"
mkdir -p "$java/${package//.//}"
mv "$java/PACKAGE_PATH/"* "$java/${package//.//}/"
rmdir "$java/PACKAGE_PATH"
ln -s ../../../../Source "$game/Android/Game/Sources/GameCompat/Source"
grep -rlI -e GAME_ -e PACKAGE_ -e APP_NAME -e XCODE_PROJECT "$game/Android/Game" "$game/Android/App" |
    while read -r file; do
        perl -pi -e "
            s/GAME_MODULE/$module/g;
            s/GAME_NAME/Template Check/g;
            s/GAME_KEY/templatecheck/g;
            s/GAME_FONTS//g;
            s/GAME_GAME_CENTER/nil/g;
            s/GAME_SIGNING_ITEM/Template Check Upload Key/g;
            s/PACKAGE_NAME/$package/g;
            s{PACKAGE_PATH}{${package//.//}}g;
            s/APP_NAME/$module/g;
            s/XCODE_PROJECT/$module/g;
        " "$file"
    done

echo "==> packing the art"
node "$RUNTIME_DIR/Tools/guard.js" 12 -- node "$RUNTIME_DIR/Tools/Art/xcassets-art.js" \
    "$game/Android/Assets" "$RUNTIME_DIR/Templates/Check/Assets.xcassets" --png

export GAME_ANDROID_DIR="$game/Android"
for abi in "${abis[@]}"; do
    "$runtime/Scripts/build-sdl.sh" "$abi"
    "$runtime/Scripts/build-shell.sh" --debug "$abi"
    # Without the Swift runtime beside it, the shell builds but can't load.
    if [ ! -f "$JNI_LIBS/$abi/libswiftCore.so" ]; then
        echo "no libswiftCore.so staged in $JNI_LIBS/$abi: the shell would not load" >&2
        exit 1
    fi
done

echo "==> assembling the APK"
abi_list="$(IFS=,; echo "${abis[*]}")"
(cd "$game/Android/App" && ./gradlew --no-daemon -q assembleDebug \
    "-Pgame.abis=$abi_list" -Pgame.versionCode=1 -Pgame.versionName=1.0)
echo "$game/Android/App/app/build/outputs/apk/debug/app-debug.apk"
