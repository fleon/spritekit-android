# The shell finds these by name over JNI: SDL's activity and its natives,
# and the methods and fields it calls and sets on the game's activity.
-keep class org.libsdl.app.** { *; }
-keep class com.spritekit.platform.SpriteKitActivity { *; }
-keep class * extends com.spritekit.platform.SpriteKitActivity { *; }
