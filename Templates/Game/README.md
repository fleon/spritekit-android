# The game package template

A game's Swift package for Android (`<game>/Android/Game`): its sources over
the runtime, its controller, and the entry whose `AndroidShell` library the
APK loads. Copy it beside the submodule (`<game>/Android/Game`, next to
`spritekit-android/` and `App/`, which comes from `../App/base`).

```
Package.swift                                   the targets and their settings
Sources/GAME_MODULEEntry/Entry.swift            SDL_main: Shell.start with the game
Sources/GameCompat/Android/AndroidGameController.swift
                                                the controller (AndroidGameHost)
```

## What a game changes

1. **Placeholders.** Replace each, everywhere under the copy:

   | Placeholder | With |
   | --- | --- |
   | `GAME_MODULE` | The game's name as a Swift identifier (`MyGame`): the package, and the entry target; rename `Sources/GAME_MODULEEntry/` to match |
   | `GAME_NAME` | The game's name as players see it (`AppIdentity.name`) |
   | `PACKAGE_NAME` | The iOS bundle ID, as the app template's |
   | `GAME_KEY` | A short lower-case key (`AppIdentity.key`): logcat, `debug.<key>.*` properties, the saved game |
   | `GAME_FONTS` | The font files staged in `fonts/`, by name (`"Nunito", "Montserrat"`) |
   | `GAME_GAME_CENTER` | The game's `GameCenterManager` (or `nil`) |

2. **Sources.** Link the game's `Source/` whole:
   `ln -s ../../../../Source Sources/GameCompat/Source`. What Android leaves
   out goes in the target's `exclude:`.
3. **Products.** Keep the runtime's and the toolkit's products the game
   imports; drop the rest.
4. **The controller.** It writes `launch(link:)` (the app delegate's launch
   work, in its order), `sceneSize(for:)`, and its splash in `init(view:)`
   (`StudioSplashLaunch`, as its view controller presents it). Everything
   else `GameHost` asks has a default in `AndroidGameHost`; a game writes its
   own where it differs (Back, keys, links, a scene told its safe area in
   `didLayout(_:)`, a `layout` of its own that calls `surface.layout`).

## How it's kept compiling

Two pull request checks build this template around a stand-in game,
`Templates/Check`, whose `Source/` has the least a game has: the title
scene and splash style the controller names, and an Apple view controller,
app delegate and scene delegate, the files `exclude:` leaves out.

- `Scripts/check-template.sh` fills the placeholders with neutral values,
  cross-compiles this package for Android, packages the APK with
  `Templates/App/base` and the CI launches it on an emulator ("Game template
  on an emulator").
- `Scripts/check-template-apple.sh` builds the same `Source/` for the iOS
  Simulator against `Platform/` and Apple's SpriteKit, its view controller
  launching through `StudioSplashScene.launch` ("Game template on iOS").

```bash
Scripts/check-template.sh x86_64         # Android: needs what build-shell.sh does
Scripts/check-template-apple.sh          # iOS: needs Xcode
```
