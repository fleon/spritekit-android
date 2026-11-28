#if !SPRITEKIT_SHIM
import AVFoundation
import Foundation
import PlatformCore
import UIKit

/// `AudioBackend` on iPhone, iPad, Apple TV and the Mac.
///
/// Sounds play from pools of `AVAudioPlayer`s, so quick repeats overlap;
/// a sound on a voice of its own gets a player of its own, let go once it
/// ends. Music streams from its file through an `AVAudioEngine`: a track
/// plays its intro once, then repeats its loop section seamlessly, and
/// tracks crossfade on player nodes of their own (`MusicDeck`).
///
/// It looks after the system's side itself: an ambient session, and picking
/// the soundtrack up where it was after an interruption, a route change or
/// the app's time in the background, which stop the engine.
///
/// Ambient mixes with other apps' audio, so the player's own music keeps
/// playing under the game's, no other app's playback interrupts it, and the
/// Ring/Silent switch silences it as it does every game. The system still
/// silences it for a call, Siri or an alarm; the soundtrack comes back as
/// they end, or at the latest as the app is next active.
public final class AppleAudioBackend: AudioBackend {
    private static let fadeStep: TimeInterval = 1.0 / 60

    private let bundle: Bundle
    private let soundExtensions: [String]
    private let musicExtensions: [String]

    private final class Pool {
        let url: URL
        let volume: Float
        let players: [AVAudioPlayer]
        var next = 0

        init(url: URL, volume: Float, players: [AVAudioPlayer]) {
            self.url = url
            self.volume = volume
            self.players = players
        }
    }
    private var pools: [String: Pool] = [:]
    private var voices: [AudioVoice: (player: AVAudioPlayer, finisher: VoiceFinisher)] = [:]
    private var nextVoice = 0

    private let engine = AVAudioEngine()
    /// Player nodes for the soundtrack: the current track's and any still
    /// fading out; idle ones are reused.
    private var decks: [MusicDeck] = []
    private var currentDeck: MusicDeck?
    private var currentTrack: String?
    private var musicVolume: Float = 1
    private var musicFade: TimeInterval = 0
    private var fadeTimer: Timer?
    /// The app is in the background: music waits for `resume()`.
    private var isInBackground = false
    private let sessionQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "app").audio-session", qos: .userInitiated)
    private let observers = ObserverBag()

    /// Starts an ambient session and listens for what stops the engine.
    /// Files are looked for in `bundle` with each extension in turn.
    public init(bundle: Bundle = .main, soundExtensions: [String] = ["wav"], musicExtensions: [String] = ["m4a", "mp3"]) {
        self.bundle = bundle
        self.soundExtensions = soundExtensions
        self.musicExtensions = musicExtensions
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
        }
        activateSession()
        observe()
    }

    private func observe() {
        func on(_ name: Notification.Name, _ object: Any? = nil, _ run: @escaping (AppleAudioBackend, Notification) -> Void) {
            observers.observe(name, object: object, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    run(self, notification)
                }
            }
        }
        on(AVAudioSession.interruptionNotification) { backend, notification in
            let info = notification.userInfo ?? [:]
            guard (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init) == .began else {
                backend.activateSession(thenRestart: true)
                return
            }
            // An interruption that came while the app was suspended is told
            // as it comes back, long over: pausing for it would keep the
            // soundtrack quiet with no end to come.
            guard info[AVAudioSessionInterruptionReasonKey] as? UInt != AVAudioSession.InterruptionReason.appWasSuspended.rawValue,
                  info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool != true else { return }
            backend.musicStopped(pausing: true)
        }
        on(.AVAudioEngineConfigurationChange, engine) { backend, _ in
            backend.musicStopped(pausing: false)
            backend.restartMusic()
        }
        on(UIApplication.didEnterBackgroundNotification) { backend, _ in backend.suspend() }
        // Active rather than entering the foreground: the app may play only
        // once it's active, and it's active again too after an interruption
        // that never said it ended (Siri, a call declined).
        on(UIApplication.didBecomeActiveNotification) { backend, _ in backend.resume() }
    }

    /// Activates the session (again, after an interruption ended it) off the
    /// main thread, then picks the soundtrack up if `thenRestart`.
    private func activateSession(thenRestart: Bool = false) {
        sessionQueue.async { [weak self] in
            try? AVAudioSession.sharedInstance().setActive(true)
            guard thenRestart else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.restartMusic() }
            }
        }
    }

    private func url(of name: String, _ extensions: [String]) -> URL? {
        AudioManager.url(of: name, extensions: extensions, in: bundle)
    }

    // MARK: Sounds

    public func prepareSounds(_ names: [String], poolSize: Int, volume: Float) {
        for name in names where pools[name] == nil {
            guard let url = url(of: name, soundExtensions) else { continue }
            let players = (0..<max(1, poolSize)).compactMap { _ -> AVAudioPlayer? in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.volume = volume
                player.prepareToPlay()
                return player
            }
            guard !players.isEmpty else { continue }
            pools[name] = Pool(url: url, volume: volume, players: players)
        }
    }

    public func duration(ofSound name: String) -> TimeInterval? {
        pools[name]?.players.first?.duration
    }

    public func play(sound name: String, rate: Float) {
        guard let pool = pools[name] else { return }
        let player = pool.players[pool.next]
        pool.next = (pool.next + 1) % pool.players.count
        player.currentTime = 0
        Self.set(rate, on: player)
        player.play()
    }

    public func play(sound name: String, rate: Float, looping: Bool) -> AudioVoice? {
        guard let pool = pools[name], let player = try? AVAudioPlayer(contentsOf: pool.url) else { return nil }
        nextVoice += 1
        let voice = AudioVoice(id: nextVoice)
        player.volume = pool.volume
        player.numberOfLoops = looping ? -1 : 0
        Self.set(rate, on: player)
        // Let go of the player on the next turn of the run loop: released
        // as it reports its end, its own end-of-playback message would reach
        // a freed player.
        let finisher = VoiceFinisher { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.voices.removeValue(forKey: voice) }
            }
        }
        player.delegate = finisher
        voices[voice] = (player, finisher)
        player.play()
        return voice
    }

    public func stop(_ voice: AudioVoice, over fade: TimeInterval) {
        guard let player = voices.removeValue(forKey: voice)?.player else { return }
        player.delegate = nil
        guard fade > 0 else {
            player.stop()
            return
        }
        player.setVolume(0, fadeDuration: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { player.stop() }
    }

    /// A player plays at another rate only once it's been told it may, before it prepares.
    private static func set(_ rate: Float, on player: AVAudioPlayer) {
        guard rate != 1 || player.enableRate else { return }
        if !player.enableRate {
            player.enableRate = true
            player.prepareToPlay()
        }
        player.rate = rate
    }

    // MARK: Music

    public func playMusic(_ track: String?, loop: MusicLoop?, volume: Float, over fade: TimeInterval) {
        musicVolume = volume
        musicFade = fade
        if track == currentTrack {
            guard let deck = currentDeck else { return }
            if deck.isPlaying {
                self.fade(deck, to: volume, over: fade)
            } else if startEngine() {
                startPlaying(deck)
            }
            return
        }
        let old = currentDeck
        currentDeck = nil
        currentTrack = track
        if let old {
            if old.isPlaying {
                self.fade(old, to: 0, over: fade)
            } else {
                old.release()
            }
        }
        guard let track, let deck = prepareDeck(for: track, loop: loop) else {
            pauseEngineIfIdle()
            return
        }
        currentDeck = deck
        if startEngine() { startPlaying(deck) }
    }

    public func suspend() {
        isInBackground = true
        musicStopped(pausing: true)
    }

    public func resume() {
        isInBackground = false
        activateSession(thenRestart: true)
    }

    /// Plays the current track again if the engine stopped under it.
    private func restartMusic() {
        if let currentDeck, startEngine(), !currentDeck.isPlaying { startPlaying(currentDeck) }
    }

    /// Opens `track` on an idle deck (or a new one) and queues it from its start.
    private func prepareDeck(for track: String, loop: MusicLoop?) -> MusicDeck? {
        guard let url = url(of: track, musicExtensions), let file = try? AVAudioFile(forReading: url) else { return nil }
        let deck = decks.first(where: \.isIdle) ?? {
            let deck = MusicDeck()
            engine.attach(deck.node)
            decks.append(deck)
            return deck
        }()
        if engine.outputConnectionPoints(for: deck.node, outputBus: 0).isEmpty || deck.node.outputFormat(forBus: 0) != file.processingFormat {
            engine.connect(deck.node, to: engine.mainMixerNode, format: file.processingFormat)
        }
        var frames: Range<AVAudioFramePosition>?
        if let loop {
            let end = min(loop.end, file.length)
            frames = 0 <= loop.start && loop.start < end ? loop.start..<end : 0..<file.length
        }
        deck.load(file, loop: frames)
        return deck
    }

    private func startPlaying(_ deck: MusicDeck) {
        deck.node.volume = 0
        deck.node.play()
        deck.isPlaying = true
        fade(deck, to: musicVolume, over: musicFade)
    }

    /// Starts the engine if it isn't running. Tracks that were playing when it
    /// stopped (an interruption, a route change, the app in the background)
    /// are queued again from where they were: a stop clears the players.
    private func startEngine() -> Bool {
        guard !isInBackground else { return false }
        guard !engine.isRunning else {
            // Still running: the players kept their place.
            for deck in decks { deck.resumeFrame = nil }
            return true
        }
        let playing = decks.filter(\.isPlaying)
        for deck in playing { deck.queue(from: deck.resumeFrame ?? deck.restartFrame) }
        do {
            try engine.start()
        } catch {
            return false
        }
        for deck in playing {
            deck.resumeFrame = nil
            deck.node.play()
        }
        return true
    }

    /// Notes where each track is when the engine stops; tracks fading out are
    /// dropped. `pausing` pauses the engine here (an interruption began, or
    /// the app went to the background); otherwise the system already stopped it.
    private func musicStopped(pausing: Bool) {
        let now = mach_absolute_time()
        for deck in decks where deck.isPlaying {
            if deck !== currentDeck {
                deck.release()
            } else if engine.isRunning || deck.resumeFrame == nil {
                // Once stopped, the first estimate is the closest.
                deck.resumeFrame = deck.frame(at: now)
            }
        }
        if pausing { engine.pause() }
    }

    /// Pauses the engine (and the audio hardware) while no track is loaded.
    private func pauseEngineIfIdle() {
        if engine.isRunning, decks.allSatisfy(\.isIdle) { engine.pause() }
    }

    private func fade(_ deck: MusicDeck, to volume: Float, over duration: TimeInterval) {
        deck.fade = MusicDeck.Fade(from: deck.node.volume, to: volume, start: ProcessInfo.processInfo.systemUptime, duration: duration)
        stepFades()
        guard fadeTimer == nil, decks.contains(where: { $0.fade != nil }) else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: Self.fadeStep, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFades() }
        }
    }

    /// Linear volume ramps; a track that faded out is stopped.
    private func stepFades() {
        let now = ProcessInfo.processInfo.systemUptime
        for deck in decks {
            guard let fade = deck.fade else { continue }
            let progress = fade.duration > 0 ? CGFloat((now - fade.start) / fade.duration).clamp(0, 1) : 1
            deck.node.volume = Float(progress.lerp(CGFloat(fade.from), CGFloat(fade.to)))
            deck.noteTime()
            guard progress == 1 else { continue }
            deck.fade = nil
            if deck !== currentDeck { deck.release() }
        }
        if decks.allSatisfy({ $0.fade == nil }) {
            fadeTimer?.invalidate()
            fadeTimer = nil
            pauseEngineIfIdle()
        }
    }
}

/// A voice's `AVAudioPlayerDelegate`: says when it has played to the end.
private final class VoiceFinisher: NSObject, AVAudioPlayerDelegate {
    private let finished: @Sendable () -> Void

    init(_ finished: @escaping @Sendable () -> Void) {
        self.finished = finished
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished()
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finished()
    }
}
#endif
