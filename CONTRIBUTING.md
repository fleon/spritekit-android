# Contributing

Thanks for helping. Bug reports, missing APIs, fixes and docs are all
welcome, from a one-line typo fix to a new node type.

## Reporting a problem

Open an issue with:

- the SpriteKit, UIKit or CoreGraphics call involved;
- what Apple does (a screenshot from iOS or a Mac helps) and what you see
  on Android;
- the device or emulator and Android version;
- ideally, a small scene that shows it.

## Making a change

1. **Match Apple exactly.** Fill a gap with SpriteKit's or Apple's exact
   signatures, so a game's code compiles unchanged. Measure the behaviour
   against Apple's on a Mac where the API runs there, and pin it in a host
   test.
2. **Keep it about SpriteKit, not about a game.** Nothing here is specific
   to any game: no game's names, identifiers, content or reasons in code,
   tests, fixtures or descriptions. Describe a change by what SpriteKit or
   Apple does, and test it with neutral fixtures. A game's own Android code
   (its controller, its managers' bodies, its Gradle app) lives in the
   game's repository.
3. **Run the checks** before you open a pull request:

   ```bash
   swift test                              # host tests
   Scripts/check-android.sh arm64-v8a      # the runtime, cross-compiled for Android
   ```

   If you touch `Platform/`, also build it for iOS, tvOS and Mac Catalyst,
   since games use it on Apple platforms too.

4. **Explain the why** in the pull request: what Apple does, what was
   wrong, and how you checked it.

## Licensing

By contributing, you agree that your contributions are licensed under the
MIT License in `LICENSE`. `Platform/Sources/PlatformRigs` is the exception: it
ports the Spine Runtimes and stays under the Spine Runtimes License.
