import Foundation

// The shortcuts every game's scenes call, on `AudioManager.shared`, so no
// game writes its own. Each plays only while its setting is on, as the
// manager does; a game's own function of the same name wins over these.

/// Plays a sound by name or by a `String` enum's case
/// (`AudioManager.play`): how long it plays, or nil when sound is off.
@discardableResult
public func playSound(_ name: String, skipIfPlaying: Bool = false, variants count: Int? = nil) -> TimeInterval? {
    AudioManager.shared.play(name, skipIfPlaying: skipIfPlaying, variants: count)
}

@discardableResult
public func playSound<S: RawRepresentable>(_ sound: S, skipIfPlaying: Bool = false) -> TimeInterval? where S.RawValue == String {
    AudioManager.shared.play(sound, skipIfPlaying: skipIfPlaying)
}

/// Plays a track (`AudioManager.playMusic`): the one already playing keeps
/// going, another crossfades in, nil fades out.
public func playMusic(_ track: String?, loop: Bool = true, variants count: Int? = nil) {
    AudioManager.shared.playMusic(track, loop: loop, variants: count)
}

public func playMusic<T: RawRepresentable>(_ track: T?, loop: Bool = true) where T.RawValue == String {
    AudioManager.shared.playMusic(track, loop: loop)
}

/// Fades the soundtrack out and forgets it.
public func stopMusic(fadeDuration: TimeInterval? = nil) {
    AudioManager.shared.stopMusic(fadeDuration: fadeDuration)
}

/// Fades the soundtrack out until `resumeMusic()`.
public func pauseMusic() {
    AudioManager.shared.pauseMusic()
}

public func resumeMusic() {
    AudioManager.shared.resumeMusic()
}
