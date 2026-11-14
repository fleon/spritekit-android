# Android's own words

The game's strings come from `Assets/<language>.lproj` unchanged, except for
the few keys here, which say what Android calls something where it differs
from Apple. Each `<language>.lproj/Localizable.strings` lists only the keys it
replaces; the Gradle task that stages the strings (`stageStrings` in
`App/app/build.gradle.kts`) swaps those lines in, and stops the build if a key
here isn't in the game's file.

| Key | Apple | Android |
|---|---|---|
| `settings.haptics` | Haptics, 触感反馈, 觸覺回饋 | Vibration, 振动, 震動 |

Every other language already calls it vibration on both platforms
("Vibración", "振動", "진동", "Вибрация", …), so only English and the two
Chinese scripts are overridden.
