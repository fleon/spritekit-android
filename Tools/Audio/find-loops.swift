// Finds a musically correct loop in each of a game's soundtrack masters and
// writes the loop points to its loops file, which `music.js export` reads to
// cut and crossfade the bundled tracks. Run through music.js (README.md
// beside this file), which hands it the game's settings:
//
//   xcrun swift -O find-loops.swift --settings <file> [--only <master>] [--debug dir]
//   xcrun swift -O find-loops.swift check --settings <file> [--seams dir]
//
// The settings file (JSON, written by music.js) holds `loops` (the loops
// file), `music` (the folder of exported .m4a files) and `tracks`, each
// `{ master, resource, file, minLoopSeconds }`: `file` is the master, in
// any format AVAudioFile reads, and a loop shorter than `minLoopSeconds`
// isn't considered.
//
// Analysis, per track, on a mono mixdown:
//   1. Onset strength (log-mel spectral flux, 5 ms hop) → tempo from its
//      autocorrelation, refined on long-lag peaks → beats by dynamic
//      programming (Ellis 2007), which follows slow drift.
//   2. Beat-synchronous chroma, timbre (z-scored log-mel), rhythm profile and
//      loudness → a beat self-similarity matrix (each feature standardised,
//      so scores read in standard deviations above a typical pair of beats).
//   3. Metre (3 or 4 beats per bar; 4 unless lags of 3 beats clearly win) and
//      downbeats (chord changes, low-end onsets and timbre changes land on
//      the one), judged locally because irregular bars shift the phase.
//   4. Intro and ending: leading and trailing bars much quieter or sparser
//      than the body (fade-in, final chord, fade-out, silence) or slowing.
//   5. Loop search over downbeat pairs (A, B), A after the intro, B before
//      the ending: the music around B must repeat the music around A (8 bars
//      before, 8 bars after, or 4 bars either side), at that exact lag rather
//      than a beat or two off, so jumping from B back to A continues the
//      phrase. Longer loops and 4/8-bar multiples earn a bonus.
//   6. Seam placement within the repeat: the downbeat whose neighbouring bars
//      match best and whose level just before the downbeat matches.
//   7. Splice: the lag is aligned on 1 ms onset envelopes, then on the
//      waveform (±15 ms, kept close to the rhythm); the seam sits just
//      before the downbeat's attack, with a 40 ms crossfade baked into the
//      file's tail by `music.js export` (`cutLoop` in lib.js).
//
// `check` decodes the exported .m4a files, confirms the AAC encoder
// delay is compensated (frame N of the file is frame N of the master), renders
// each seam through AVAudioPlayerNode exactly as AudioManager schedules it, and
// prints objective seam metrics; `--seams dir` also writes every seam (4 s
// before the loop end, then 4 s from the loop start) as a WAV.
import AVFoundation
import Accelerate
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Settings

private let hopSeconds = 0.005
private let onsetFFTSize = 2048
private let chromaFFTSize = 8192
private let chromaHopSeconds = 0.025
private let melBandCount = 40
private let fluxLagFrames = 4
private let tempoPriorBPM = 120.0
private let beatTightness = 100.0
private let minLoopBars = 8
/// Seam context windows, in bars.
private let contextBars = 8
private let straddleBars = 4
/// Ranking bonuses (in standard deviations of beat similarity) per doubling
/// of the loop length and for 8-bar multiples (half for 4-bar ones), and the
/// match a seam needs to be trusted.
private let lengthBonus: Float = 0.3
private let phraseBonus: Float = 0.15
private let minimumMatch: Float = 1.0
/// Seam placement: how much weaker than the best match a seam may be, and
/// the penalty per dB of level difference just before the downbeat.
private let seamTolerance: Float = 0.3
private let levelPenalty: Float = 0.1
private let crossfadeSeconds = 0.04
/// The seam lands this long before the downbeat's attack.
private let attackLeadSeconds = 0.012
private let waveSearchSeconds = 0.015
/// The waveform alignment pays 0.5 (in correlation) for straying this far
/// from the rhythmic alignment, which matters more.
private let strayScaleSeconds = 0.003
private let fineHopSamples = 48

/// One soundtrack master and the file it's exported to.
struct Track {
    var master: String
    var resource: String
    var file: URL
    var minLoopSeconds: Double
}

/// The game's settings, from the file music.js writes (`--settings`).
struct Settings {
    var loops: URL
    var music: URL
    var tracks: [Track]

    init(contentsOf url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let loops = json["loops"] as? String, let music = json["music"] as? String,
              let tracks = json["tracks"] as? [[String: Any]] else { throw fail("Bad settings file \(url.path)") }
        self.loops = URL(fileURLWithPath: loops)
        self.music = URL(fileURLWithPath: music)
        self.tracks = try tracks.map { track in
            guard let master = track["master"] as? String, let resource = track["resource"] as? String,
                  let file = track["file"] as? String else { throw fail("Bad track in \(url.path)") }
            return Track(master: master, resource: resource, file: URL(fileURLWithPath: file),
                         minLoopSeconds: (track["minLoopSeconds"] as? Double) ?? 0)
        }
    }
}

func fail(_ message: String) -> NSError {
    NSError(domain: "find-loops", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// MARK: - Audio

struct Audio {
    var channels: [[Float]]
    var sampleRate: Double
    var count: Int { channels[0].count }

    var mono: [Float] {
        channels.count == 1 ? channels[0] : vDSP.multiply(0.5, vDSP.add(channels[0], channels[1]))
    }
}

func loadAudio(_ url: URL, frames: Range<Int>? = nil) throws -> Audio {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let range = frames ?? 0..<Int(file.length)
    file.framePosition = AVAudioFramePosition(range.lowerBound)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else {
        throw fail("Cannot allocate \(range.count) frames")
    }
    try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
    guard let data = buffer.floatChannelData else { throw fail("No float data in \(url.lastPathComponent)") }
    let n = Int(buffer.frameLength)
    let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    return Audio(channels: channels, sampleRate: format.sampleRate)
}

func writeWAV(_ url: URL, channels: [[Float]], sampleRate: Double) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)),
          let data = buffer.floatChannelData else { throw fail("Cannot allocate \(url.lastPathComponent)") }
    buffer.frameLength = AVAudioFrameCount(channels[0].count)
    for (c, samples) in channels.enumerated() {
        samples.withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: samples.count) }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels.count,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

// MARK: - Spectra

final class RealFFT {
    let size: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var frame: [Float]

    init(size: Int) {
        self.size = size
        log2Size = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        frame = [Float](repeating: 0, count: size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Power spectrum (size/2 + 1 bins) of the Hann-windowed frame centred on
    /// `center`; samples outside the signal count as silence.
    func power(_ x: UnsafeBufferPointer<Float>, center: Int, into out: inout [Float]) {
        let start = center - size / 2
        for i in 0..<size {
            let j = start + i
            frame[i] = (j >= 0 && j < x.count) ? x[j] * window[i] : 0
        }
        let half = size / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                out[0] = rp[0] * rp[0] / 4
                out[half] = ip[0] * ip[0] / 4
                for k in 1..<half { out[k] = (rp[k] * rp[k] + ip[k] * ip[k]) / 4 }
            }
        }
    }
}

/// Triangular filters on the mel scale: for each band, (bin, weight) pairs.
func melFilterbank(bands: Int, fftSize: Int, sampleRate: Double, minHz: Double, maxHz: Double) -> [[(Int, Float)]] {
    func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
    func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
    let lo = mel(minHz), hi = mel(maxHz)
    let edges = (0...(bands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
    let binHz = sampleRate / Double(fftSize)
    return (0..<bands).map { b in
        let left = edges[b], mid = edges[b + 1], right = edges[b + 2]
        var weights: [(Int, Float)] = []
        for k in max(1, Int(left / binHz))...min(fftSize / 2, Int(right / binHz) + 1) {
            let f = Double(k) * binHz
            let w = f <= mid ? (f - left) / (mid - left) : (right - f) / (right - mid)
            if w > 0 { weights.append((k, Float(w))) }
        }
        if weights.isEmpty { weights.append((min(fftSize / 2, max(1, Int((mid / binHz).rounded()))), 1)) }
        return weights
    }
}

/// Log-mel spectrogram (dB, frames × bands, row-major) and per-frame power.
func melSpectrogram(_ x: [Float], sampleRate: Double, fftSize: Int, hop: Int, bands: Int, minHz: Double = 30, maxHz: Double = 16000,
                    range: Range<Int>? = nil) -> (db: [Float], power: [Float], frames: Int) {
    let fft = RealFFT(size: fftSize)
    let bank = melFilterbank(bands: bands, fftSize: fftSize, sampleRate: sampleRate, minHz: minHz, maxHz: maxHz)
    let r = range ?? 0..<x.count
    let frames = r.count / hop + 1
    var spectrum = [Float](repeating: 0, count: fftSize / 2 + 1)
    var db = [Float](repeating: 0, count: frames * bands)
    var power = [Float](repeating: 0, count: frames)
    x.withUnsafeBufferPointer { xp in
        for t in 0..<frames {
            fft.power(xp, center: r.lowerBound + t * hop, into: &spectrum)
            var total: Float = 0
            for b in 0..<bands {
                var s: Float = 0
                for (k, w) in bank[b] { s += spectrum[k] * w }
                db[t * bands + b] = 10 * log10(max(s, 1e-10))
                total += s
            }
            power[t] = total
        }
    }
    return (db, power, frames)
}

/// Half-wave rectified spectral flux of a log-mel spectrogram (mean dB rise).
func spectralFlux(_ db: [Float], frames: Int, bands: Int, lag: Int, bandRange: Range<Int>? = nil, floor: Float? = nil) -> [Float] {
    let br = bandRange ?? 0..<bands
    let lowest = floor ?? ((db.max() ?? 0) - 80)
    var flux = [Float](repeating: 0, count: frames)
    for t in lag..<frames {
        var s: Float = 0
        for b in br { s += max(0, max(db[t * bands + b], lowest) - max(db[(t - lag) * bands + b], lowest)) }
        flux[t] = s / Float(br.count)
    }
    return flux
}

/// Onset envelope with a 1 ms hop over `range`.
func fineOnset(_ x: [Float], sampleRate: Double, range: Range<Int>) -> [Float] {
    let spec = melSpectrogram(x, sampleRate: sampleRate, fftSize: 512, hop: fineHopSamples, bands: 24, minHz: 80, maxHz: 16000, range: range)
    let flux = spectralFlux(spec.db, frames: spec.frames, bands: 24, lag: 3)
    return zip(flux, movingAverage(flux, radius: 100)).map { max(0, $0 - $1) }
}

func movingAverage(_ x: [Float], radius: Int) -> [Float] {
    var prefix = [Double](repeating: 0, count: x.count + 1)
    for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
    return (0..<x.count).map { i in
        let a = max(0, i - radius), b = min(x.count, i + radius + 1)
        return Float((prefix[b] - prefix[a]) / Double(b - a))
    }
}

func normalized(_ v: [Float]) -> [Float] {
    let n = sqrt(vDSP.sumOfSquares(v))
    return n > 1e-12 ? vDSP.divide(v, n) : v
}

func zscores(_ v: [Float]) -> [Float] {
    let mean = vDSP.mean(v)
    let sd = max(sqrt(vDSP.meanSquare(vDSP.add(-mean, v))), 1e-6)
    return v.map { ($0 - mean) / sd }
}

func median(_ v: [Float]) -> Float { percentile(v, 0.5) }

func percentile(_ v: [Float], _ p: Double) -> Float {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
}

/// Sub-sample peak offset from three neighbouring values.
func parabolicOffset(_ y0: Double, _ y1: Double, _ y2: Double) -> Double {
    let d = y0 - 2 * y1 + y2
    guard abs(d) > 1e-12 else { return 0 }
    return max(-0.5, min(0.5, 0.5 * (y0 - y2) / d))
}

/// Shift (in frames, sub-frame) within ±`maxShift` at which `b` best lines up
/// with `a`, using weights per frame of `a`; with the peak correlation.
func alignment(_ a: [Float], _ b: [Float], aCentre: Int, bCentre: Int, frames: Range<Int>, maxShift: Int, weight: (Int) -> Double) -> (shift: Double, r: Double) {
    var correlations: [Double] = []
    for shift in -maxShift...maxShift {
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in frames {
            let ia = aCentre + k, ib = bCentre + k + shift
            guard ia >= 0, ia < a.count, ib >= 0, ib < b.count else { continue }
            let w = weight(k)
            dot += w * Double(a[ia] * b[ib])
            na += w * Double(a[ia] * a[ia])
            nb += w * Double(b[ib] * b[ib])
        }
        correlations.append(dot / max(sqrt(na * nb), 1e-12))
    }
    var peak = maxShift
    for i in correlations.indices where correlations[i] > correlations[peak] { peak = i }
    var shift = Double(peak - maxShift)
    if peak > 0, peak < correlations.count - 1 {
        shift += parabolicOffset(correlations[peak - 1], correlations[peak], correlations[peak + 1])
    }
    return (shift, correlations[peak])
}

// MARK: - Tempo and beats

func autocorrelation(_ x: [Float], maxLag: Int) -> [Float] {
    let centred = vDSP.add(-vDSP.mean(x), x)
    var ac = [Float](repeating: 0, count: maxLag + 1)
    centred.withUnsafeBufferPointer { p in
        for lag in 0...maxLag {
            var s: Float = 0
            vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(centred.count - lag))
            ac[lag] = s / Float(centred.count - lag)
        }
    }
    return ac
}

/// Normalised autocorrelation near a (fractional) lag: the best within ±2 frames.
func autocorrelation(_ x: [Float], near lag: Double) -> Float {
    let centred = vDSP.add(-vDSP.mean(x), x)
    let energy = max(vDSP.sumOfSquares(centred), 1e-12)
    let centre = Int(lag.rounded())
    return centred.withUnsafeBufferPointer { p in
        (max(1, centre - 2)...min(x.count - 1, centre + 2)).map { l -> Float in
            var s: Float = 0
            vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + l, 1, &s, vDSP_Length(centred.count - l))
            return s / energy
        }.max() ?? 0
    }
}

/// Beat period in frames: the autocorrelation peak nearest the tempo prior,
/// refined on the peaks at 2, 4, 8, … beats while they stay pronounced.
func estimatePeriod(_ onset: [Float], fps: Double) -> Double {
    let maxLag = min(onset.count - 2, Int(fps * 60))
    let ac = autocorrelation(onset, maxLag: maxLag)
    var best = (lag: 0, score: -Float.infinity)
    for lag in Int(fps * 60 / 220)...Int(fps * 60 / 50) {
        guard ac[lag] > ac[lag - 1], ac[lag] >= ac[lag + 1] else { continue }
        let prior = Float(exp(-0.5 * pow(log2(60 * fps / Double(lag) / tempoPriorBPM), 2)))
        if ac[lag] * prior > best.score { best = (lag, ac[lag] * prior) }
    }
    var period = Double(best.lag)
    let reference = ac[best.lag]
    for k in [2, 4, 8, 16, 32, 64] {
        let centre = period * Double(k)
        let lo = Int(centre - 3), hi = Int(centre + 3)
        guard hi + 1 <= maxLag, lo > 1 else { break }
        var peak = lo
        for lag in lo...hi where ac[lag] > ac[peak] { peak = lag }
        guard ac[peak] > 0.5 * reference, peak > lo, peak < hi else { break }
        period = (Double(peak) + parabolicOffset(Double(ac[peak - 1]), Double(ac[peak]), Double(ac[peak + 1]))) / Double(k)
    }
    return period
}

/// Dynamic-programming beat tracker; returns beat frames.
func trackBeats(_ onset: [Float], period: Double) -> [Int] {
    let n = onset.count
    let sigma = period / 32
    let radius = Int(ceil(sigma * 4))
    let gaussian = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
    let kernel = vDSP.divide(gaussian, gaussian.reduce(0, +))
    var local = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var s: Float = 0
        for (j, w) in kernel.enumerated() where i + j - radius >= 0 && i + j - radius < n { s += onset[i + j - radius] * w }
        local[i] = s
    }
    let lo = max(1, Int((period / 2).rounded())), hi = Int((period * 2).rounded())
    let penalty = (0...hi).map { $0 < lo ? 0 : -beatTightness * pow(log(Double($0) / period), 2) }
    var score = [Double](repeating: 0, count: n)
    var back = [Int](repeating: -1, count: n)
    for i in 0..<n {
        var best = -Double.infinity, arg = -1
        if i >= lo {
            for d in lo...min(hi, i) where score[i - d] + penalty[d] > best {
                best = score[i - d] + penalty[d]
                arg = i - d
            }
        }
        score[i] = Double(local[i]) + (arg >= 0 ? max(best, 0) : 0)
        back[i] = arg >= 0 && best > 0 ? arg : -1
    }
    // The last beat: the last local maximum of the cumulative score that
    // reaches half the median of all local maxima.
    var maxima: [Int] = []
    for i in 1..<(n - 1) where score[i] > score[i - 1] && score[i] >= score[i + 1] { maxima.append(i) }
    let threshold = 0.5 * Double(median(maxima.map { Float(score[$0]) }))
    var i = maxima.last { score[$0] >= threshold } ?? n - 1
    var beats: [Int] = []
    while i >= 0 {
        beats.append(i)
        i = back[i]
    }
    return beats.reversed()
}

// MARK: - Analysis

struct BeatFeatures {
    var chroma: [[Float]] = []
    var timbre: [[Float]] = []
    var rhythm: [[Float]] = []
    var loudness: [Float] = []
    var onsetStrength: [Float] = []
    var lowOnset: [Float] = []
    /// Level (dB) just before each beat, where a seam's crossfade happens.
    var leadIn: [Float] = []
}

struct LoopChoice {
    var a: Int
    var b: Int
    /// Best of the window matches below (exact similarity plus contrast).
    var score: Float
    var before: Float?
    var after: Float?
    var around: Float?
    var basis: String
    /// Similarity of the bar either side of the seam, less the level penalty.
    var context: Float = 0
}

struct Splice {
    var start: Int
    var end: Int
    var crossfade: Int
    var correlation: Float
}

struct TrackAnalysis {
    var sampleRate: Double
    var frameCount: Int
    var bpm: Double
    var beatsPerBar: Int
    var beatSamples: [Double]
    var introEndBeat: Int
    var endingStartBeat: Int
    var loop: LoopChoice
    var splice: Splice
    var notes: [String]
}

func analyze(name: String, url: URL, minLoopSeconds: Double, debugDir: URL?) throws -> TrackAnalysis {
    let audio = try loadAudio(url)
    let sr = audio.sampleRate
    let x = audio.mono
    let hop = Int((sr * hopSeconds).rounded())
    let fps = sr / Double(hop)
    var notes: [String] = []
    var log: [String] = []

    // Onset strength.
    let mel = melSpectrogram(x, sampleRate: sr, fftSize: onsetFFTSize, hop: hop, bands: melBandCount)
    let frames = mel.frames
    let flux = spectralFlux(mel.db, frames: frames, bands: melBandCount, lag: fluxLagFrames)
    let lowFlux = spectralFlux(mel.db, frames: frames, bands: melBandCount, lag: fluxLagFrames, bandRange: 0..<6)
    var onset = zip(flux, movingAverage(flux, radius: Int(fps * 0.2))).map { max(0, $0 - $1) }
    onset = vDSP.divide(onset, max(sqrt(vDSP.meanSquare(onset)), 1e-9))

    // Tempo and beats; beats in leading or trailing silence are dropped.
    let period = estimatePeriod(onset, fps: fps)
    var beatFrames = trackBeats(onset, period: period)
    let silence = 10 * log10(max(vDSP.mean(mel.power), 1e-12)) - 45
    func frameDB(_ t: Int) -> Float { 10 * log10(max(mel.power[min(max(t, 0), frames - 1)], 1e-12)) }
    while beatFrames.count > 8, frameDB(beatFrames[0]) < silence, frameDB(beatFrames[0] + Int(period)) < silence { beatFrames.removeFirst() }
    while beatFrames.count > 8, let last = beatFrames.last, frameDB(last) < silence, frameDB(last - Int(period)) < silence { beatFrames.removeLast() }
    let intervals = zip(beatFrames.dropFirst(), beatFrames).map { Float($0 - $1) }
    let bpm = 60 * fps / period
    let beatCount = beatFrames.count - 1  // beats with a full interval
    guard beatCount > 64 else { throw fail("\(name): too few beats") }

    // Chromagram.
    let chromaHop = Int((sr * chromaHopSeconds).rounded())
    let chromaFFT = RealFFT(size: chromaFFTSize)
    let chromaFrames = x.count / chromaHop + 1
    var pitchBins: [(bin: Int, pitch: Int, weight: Float)] = []
    for k in 1..<(chromaFFTSize / 2) {
        let f = Double(k) * sr / Double(chromaFFTSize)
        guard f >= 60, f <= 4200 else { continue }
        let p = 12 * log2(f / 440) + 69
        let w = Float(max(0, 1 - 2 * abs(p - p.rounded())))
        if w > 0 { pitchBins.append((k, ((Int(p.rounded()) % 12) + 12) % 12, w)) }
    }
    var chromaGram = [Float](repeating: 0, count: chromaFrames * 12)
    var spectrum = [Float](repeating: 0, count: chromaFFTSize / 2 + 1)
    x.withUnsafeBufferPointer { xp in
        for t in 0..<chromaFrames {
            chromaFFT.power(xp, center: t * chromaHop, into: &spectrum)
            for (k, c, w) in pitchBins { chromaGram[t * 12 + c] += spectrum[k] * w }
        }
    }

    // Beat-synchronous features.
    var features = BeatFeatures()
    for i in 0..<beatCount {
        let a = beatFrames[i], b = beatFrames[i + 1]
        var bands = [Float](repeating: 0, count: melBandCount)
        var power: Float = 0
        for t in a..<b {
            for k in 0..<melBandCount { bands[k] += mel.db[t * melBandCount + k] }
            power += mel.power[t]
        }
        features.timbre.append(vDSP.divide(bands, Float(b - a)))
        features.loudness.append(10 * log10(max(power / Float(b - a), 1e-12)))
        let ca = Int((Double(a * hop) / Double(chromaHop)).rounded())
        let cb = max(ca + 1, Int((Double(b * hop) / Double(chromaHop)).rounded()))
        var chroma = [Float](repeating: 0, count: 12)
        for t in ca..<min(cb, chromaFrames) { for c in 0..<12 { chroma[c] += chromaGram[t * 12 + c] } }
        features.chroma.append(normalized(chroma.map { sqrt($0) }))
        // Rhythm: the strongest onset in each eighth of the beat.
        var rhythm = [Float](repeating: 0, count: 8)
        for t in a..<b { rhythm[min(7, (t - a) * 8 / (b - a))] = max(rhythm[min(7, (t - a) * 8 / (b - a))], onset[t]) }
        features.rhythm.append(rhythm)
        let around = max(0, a - 3)...min(frames - 1, a + 3)
        features.onsetStrength.append(around.map { onset[$0] }.max() ?? 0)
        features.lowOnset.append(around.map { lowFlux[$0] }.max() ?? 0)
        let lead = max(0, a - Int(0.15 * fps))..<max(1, a - Int(0.03 * fps))
        features.leadIn.append(10 * log10(max(lead.map { mel.power[$0] }.reduce(0, +) / Float(lead.count), 1e-12)))
    }
    for k in 0..<melBandCount {
        let column = features.timbre.map { $0[k] }
        let mean = vDSP.mean(column)
        let sd = max(1, sqrt(vDSP.meanSquare(vDSP.add(-mean, column))))
        for i in 0..<beatCount { features.timbre[i][k] = (features.timbre[i][k] - mean) / sd }
    }
    features.timbre = features.timbre.map(normalized)
    let rhythmScale = max(percentile(features.rhythm.flatMap { $0 }, 0.95), 1e-6)
    features.rhythm = features.rhythm.map { normalized($0.map { min($0 / rhythmScale, 1) }) }

    // Beat self-similarity: each feature standardised over the track, mixed.
    let n = beatCount
    var parts = [[Float]](repeating: [Float](repeating: 0, count: n * n), count: 4)
    for i in 0..<n {
        for j in i..<n {
            let values: [Float] = [
                vDSP.dot(features.chroma[i], features.chroma[j]),
                vDSP.dot(features.timbre[i], features.timbre[j]),
                vDSP.dot(features.rhythm[i], features.rhythm[j]),
                -abs(features.loudness[i] - features.loudness[j]),
            ]
            for f in 0..<4 {
                parts[f][i * n + j] = values[f]
                parts[f][j * n + i] = values[f]
            }
        }
    }
    let featureWeights: [Float] = [0.4, 0.3, 0.15, 0.15]
    var sim = [Float](repeating: 0, count: n * n)
    for f in 0..<4 {
        var total = 0.0, squares = 0.0, count = 0.0
        for i in 0..<n {
            for j in stride(from: i + 4, to: n, by: 1) {
                let v = Double(parts[f][i * n + j])
                total += v
                squares += v * v
                count += 1
            }
        }
        let mean = Float(total / count)
        let sd = Float(max(sqrt(squares / count - pow(total / count, 2)), 1e-6))
        for k in 0..<(n * n) { sim[k] += featureWeights[f] * (parts[f][k] - mean) / sd }
    }
    func s(_ i: Int, _ j: Int) -> Float { sim[i * n + j] }
    func lagMean(_ lag: Int) -> Float { (0..<(n - lag)).map { s($0, $0 + lag) }.reduce(0, +) / Float(n - lag) }

    // Metre: similarity at lags that are multiples of 3 (not 4) against
    // multiples of 4 (not 3), confirmed by onset accents every 3 beats.
    let threes = [3, 6, 9, 15, 18, 21, 27, 30, 33].map(lagMean).reduce(0, +) / 9
    let fours = [4, 8, 16, 20, 28, 32, 40, 44].map(lagMean).reduce(0, +) / 8
    let triple = threes > fours + 0.03 && autocorrelation(onset, near: period * 3) > autocorrelation(onset, near: period * 4)
    let beatsPerBar = triple ? 3 : 4
    if triple { notes.append("triple metre") }

    // Downbeats: chord changes (bar-level, then half-bar), low-end onsets and
    // timbre changes, averaged per phase over the surrounding 24 bars.
    func change(_ series: [[Float]], at i: Int, span: Int) -> Float {
        guard i >= span, i + span <= series.count else { return 0 }
        var before = [Float](repeating: 0, count: series[0].count), after = before
        for k in 0..<span {
            before = vDSP.add(before, series[i - 1 - k])
            after = vDSP.add(after, series[i + k])
        }
        return 1 - vDSP.dot(normalized(before), normalized(after))
    }
    let shiftedTimbre = features.timbre.map { $0.map { $0 + 1 } }
    let cues: [(weight: Float, values: [Float])] = [
        (0.45, zscores((0..<n).map { change(features.chroma, at: $0, span: beatsPerBar) })),
        (0.25, zscores((0..<n).map { change(features.chroma, at: $0, span: 2) })),
        (0.15, zscores(features.lowOnset)),
        (0.15, zscores((0..<n).map { change(shiftedTimbre, at: $0, span: 2) })),
    ]
    let evidence = (0..<n).map { i in cues.reduce(Float(0)) { $0 + $1.weight * $1.values[i] } }
    func phaseScores(around centre: Int?) -> [Float] {
        (0..<beatsPerBar).map { phase in
            let beats = stride(from: phase, to: n, by: beatsPerBar).filter { beat in centre.map { abs(beat - $0) <= 12 * beatsPerBar } ?? true }
            return beats.isEmpty ? 0 : beats.map { evidence[$0] }.reduce(0, +) / Float(beats.count)
        }
    }
    let globalScores = phaseScores(around: nil)
    let downbeatPhase = globalScores.indices.max { globalScores[$0] < globalScores[$1] } ?? 0
    let localPhase = (0..<n).map { i -> Int in
        let scores = phaseScores(around: i)
        return scores.indices.max { scores[$0] < scores[$1] } ?? 0
    }
    func isDownbeat(_ i: Int) -> Bool { (i - localPhase[i]) % beatsPerBar == 0 }
    let ranked = globalScores.sorted(by: >)
    if ranked[0] - ranked[1] < 0.05 { notes.append("downbeat uncertain") }

    // Intro and ending: leading and trailing bars much quieter or sparser than
    // the body; a slowing final cadence also belongs to the ending.
    let bars = Array(stride(from: downbeatPhase, to: n - beatsPerBar + 1, by: beatsPerBar))
    let barLoudness = bars.map { b in 10 * log10(max((0..<beatsPerBar).map { pow(10, features.loudness[b + $0] / 10) }.reduce(0, +) / Float(beatsPerBar), 1e-12)) }
    let barActivity = bars.map { b in (0..<beatsPerBar).map { features.onsetStrength[b + $0] }.reduce(0, +) / Float(beatsPerBar) }
    let referenceLoudness = percentile(barLoudness, 0.6), referenceActivity = percentile(barActivity, 0.6)
    func weakBar(_ k: Int) -> Bool { barLoudness[k] < referenceLoudness - 9 || barActivity[k] < 0.3 * referenceActivity }
    var introBar = 0
    while introBar < bars.count - 2, weakBar(introBar) || weakBar(introBar + 1) { introBar += 1 }
    var endBar = bars.count
    while endBar > introBar + 2, weakBar(endBar - 1) { endBar -= 1 }
    let typicalInterval = median(intervals)
    while endBar > introBar + 2 {
        let first = bars[endBar - 1], last = min(intervals.count, first + beatsPerBar)
        guard intervals[first..<last].reduce(0, +) / Float(last - first) > typicalInterval * 1.03 else { break }
        endBar -= 1
    }
    let introEnd = bars[introBar]
    let endingStart = endBar < bars.count ? bars[endBar] : n

    // Loop search. A window's match is its mean similarity plus its contrast
    // against the same window shifted by one or two beats: a true repeat
    // lines up only at the exact lag, a uniform texture at any lag.
    let context = contextBars * beatsPerBar, straddle = straddleBars * beatsPerBar
    func window(_ range: Range<Int>, _ a: Int, _ b: Int) -> (exact: Float, contrast: Float)? {
        guard a + range.lowerBound >= 0, b + range.lowerBound - 2 >= 0, b + range.upperBound + 2 <= n else { return nil }
        var exact: Float = 0, shifted: Float = 0
        for k in range {
            exact += s(a + k, b + k)
            shifted += s(a + k, b + k - 2) + s(a + k, b + k - 1) + s(a + k, b + k + 1) + s(a + k, b + k + 2)
        }
        let count = Float(range.count)
        return (exact / count, (exact - shifted / 4) / count)
    }
    func evaluate(_ a: Int, _ b: Int) -> LoopChoice {
        let score = { (w: (exact: Float, contrast: Float)?) in w.map { $0.exact + $0.contrast } }
        let before = score(window(-context..<0, a, b))
        let after = b + context <= endingStart ? score(window(0..<context, a, b)) : nil
        let around = b + straddle <= endingStart ? score(window(-straddle..<straddle, a, b)) : nil
        let best = [(before, "before"), (after, "after"), (around, "around")].compactMap { v, basis in v.map { ($0, basis) } }.max { $0.0 < $1.0 }
        return LoopChoice(a: a, b: b, score: best?.0 ?? -.infinity, before: before, after: after, around: around, basis: best?.1 ?? "none")
    }
    let firstA = max(introEnd, straddle)
    var candidates: [LoopChoice] = []
    let beatSeconds = Double(typicalInterval) / fps
    let minLag = max(minLoopBars * beatsPerBar, Int((minLoopSeconds / beatSeconds).rounded(.up)))
    for lag in stride(from: minLag, through: endingStart - firstA, by: 1) {
        let best = stride(from: firstA, through: endingStart - lag, by: 1).filter(isDownbeat).map { evaluate($0, $0 + lag) }.max { $0.score < $1.score }
        if let best { candidates.append(best) }
    }
    // Rank: match, plus a bonus per doubling of length and for phrase lengths;
    // a candidate under `minimumMatch` only wins when none reaches it.
    func rank(_ c: LoopChoice) -> Float {
        let lag = c.b - c.a
        let phrase = lag % (beatsPerBar * 8) == 0 ? phraseBonus : lag % (beatsPerBar * 4) == 0 ? phraseBonus / 2 : 0
        return (c.score >= minimumMatch ? 100 : 0) + c.score + lengthBonus * log2(Float(lag) / Float(beatsPerBar)) + phrase
    }
    guard let winner = candidates.max(by: { rank($0) < rank($1) }) else { throw fail("\(name): no loop candidates") }

    // Seam placement: among downbeats at the winning lag whose match is close
    // to the best, the one whose neighbouring bars match best and whose level
    // just before the downbeat (where the crossfade happens) matches.
    let lag = winner.b - winner.a
    var loop = winner
    loop.context = -.infinity
    for a in stride(from: firstA, through: endingStart - lag, by: 1) where isDownbeat(a) {
        var choice = evaluate(a, a + lag)
        guard choice.score >= winner.score - seamTolerance, let near = window(-beatsPerBar..<beatsPerBar, a, a + lag) else { continue }
        choice.context = near.exact - levelPenalty * abs(features.leadIn[a] - features.leadIn[a + lag])
        if choice.context > loop.context { loop = choice }
    }
    if !loop.context.isFinite { loop.context = 0 }
    if loop.score < minimumMatch { notes.append(String(format: "weak match: no repeat reaches %.1f", minimumMatch)) }

    let beatSamples = beatFrames.map { Double($0 * hop) }
    let splice = refineSplice(audio: audio, x: x, a: beatSamples[loop.a], b: beatSamples[loop.b], basis: loop.basis,
                              bar: (beatSamples[loop.a + beatsPerBar] - beatSamples[loop.a]), endingSample: beatSamples[min(endingStart, n)],
                              notes: &notes, log: &log)

    if let debugDir {
        // Bar chords (top three pitch classes) and raw feature similarity around the seam.
        let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
        let chords = bars.dropLast().enumerated().map { k, start -> String in
            let c = (start..<(start + beatsPerBar)).reduce([Float](repeating: 0, count: 12)) { vDSP.add($0, features.chroma[$1]) }
            return String(format: "%d@%d:%@", k, start, c.indices.sorted { c[$0] > c[$1] }.prefix(3).map { names[$0] }.joined())
        }
        for (f, label) in ["chroma", "timbre", "rhythm", "level"].enumerated() {
            func mean(_ r: Range<Int>) -> String {
                let ks = r.filter { loop.a + $0 >= 0 && loop.b + $0 < n }
                return ks.isEmpty ? "-" : String(format: "%.2f", ks.map { parts[f][(loop.a + $0) * n + loop.b + $0] }.reduce(0, +) / Float(ks.count))
            }
            log.append("\(label) at the seam: 8 bars before \(mean(-context..<0)), a bar either side \(mean(-beatsPerBar..<beatsPerBar)), 8 bars after \(mean(0..<context))")
        }
        let phases = globalScores.map { String(format: "%.2f", $0) }.joined(separator: " ")
        var lines: [String] = [
            String(format: "%@: %.3f BPM, %d beats, %d/bar (lag similarity threes %.3f, fours %.3f), downbeat phase %d (%@)",
                   name, bpm, n, beatsPerBar, threes, fours, downbeatPhase, phases),
            String(format: "intro ends at beat %d, ending starts at beat %d, loop a=%d b=%d (%@ %.3f, context %.3f)",
                   introEnd, endingStart, loop.a, loop.b, loop.basis, loop.score, loop.context),
        ]
        lines += log
        lines += ["", "candidates (best seam per lag, by rank):"]
        func show(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
        for c in candidates.sorted(by: { rank($0) > rank($1) }).prefix(30) {
            let bars = Float(c.b - c.a) / Float(beatsPerBar)
            lines.append(String(format: "%6.2f bars  %6.3f (%@)  rank %6.3f  a=%d b=%d  ", bars, c.score, c.basis, rank(c), c.a, c.b)
                         + "before \(show(c.before)) after \(show(c.after)) around \(show(c.around))")
        }
        lines += ["", "bar chords:"]
        for row in stride(from: 0, to: chords.count, by: 8) { lines.append(chords[row..<min(chords.count, row + 8)].joined(separator: "  ")) }
        try lines.joined(separator: "\n").write(to: debugDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: String.Encoding.utf8)
        writeSimilarityImage(debugDir.appendingPathComponent("\(name).png"), sim: sim, count: n, loudness: features.loudness,
                             loop: [loop.a, loop.b], bounds: [introEnd, endingStart], grid: (downbeatPhase, beatsPerBar * 4))
    }

    return TrackAnalysis(sampleRate: sr, frameCount: audio.count, bpm: bpm, beatsPerBar: beatsPerBar, beatSamples: beatSamples,
                         introEndBeat: introEnd, endingStartBeat: endingStart, loop: loop, splice: splice, notes: notes)
}

/// Sample-accurate loop points around beat positions `a` and `b` (samples).
func refineSplice(audio: Audio, x: [Float], a: Double, b: Double, basis: String, bar: Double, endingSample: Double,
                  notes: inout [String], log: inout [String]) -> Splice {
    let sr = audio.sampleRate
    // 1. Rhythm: align the lag on 1 ms onset envelopes over the two bars that
    //    matched on each side, Hann-weighted toward the seam.
    let search = Int(0.04 * sr)
    let before = basis == "after" ? 0 : Int(2 * bar)
    let after = basis == "before" ? 0 : min(Int(2 * bar), max(0, Int(endingSample - b) - search))
    let aLower = max(0, Int(a) - before - search), bLower = max(0, Int(b) - before - search)
    let ea = fineOnset(x, sampleRate: sr, range: aLower..<min(x.count, Int(a) + after + search))
    let eb = fineOnset(x, sampleRate: sr, range: bLower..<min(x.count, Int(b) + after + search))
    let beforeFrames = before / fineHopSamples, afterFrames = after / fineHopSamples
    let maxShift = search / fineHopSamples
    let rhythm = alignment(ea, eb, aCentre: (Int(a) - aLower) / fineHopSamples, bCentre: (Int(b) - bLower) / fineHopSamples,
                           frames: -beforeFrames..<afterFrames, maxShift: maxShift) { k in
        0.5 + 0.5 * cos(Double.pi * Double(k) / Double(max(k < 0 ? beforeFrames : afterFrames, 1)))
    }
    if abs(rhythm.shift) >= Double(maxShift) - 0.5 { notes.append("rhythmic alignment hit its search limit") }
    let lag = b + rhythm.shift * Double(fineHopSamples) - a

    // 2. Seam: just before the attack of A's downbeat.
    let attackWindow = Int(0.035 * sr), span = Int(0.15 * sr)
    let attackLower = max(0, Int(a) - span)
    let attackEnvelope = fineOnset(x, sampleRate: sr, range: attackLower..<min(x.count, Int(a) + span))
    let attackFrame = attackEnvelope.indices.filter { abs($0 * fineHopSamples + attackLower - Int(a)) <= attackWindow }.max { attackEnvelope[$0] < attackEnvelope[$1] }
    let attack = attackFrame.map { attackLower + $0 * fineHopSamples } ?? Int(a)
    let crossfade = Int((crossfadeSeconds * sr).rounded())
    let start = max(Int((Double(attack) - attackLeadSeconds * sr).rounded()), crossfade + 1)

    // 3. Waveform: correlate the crossfade region (stereo, ±10 ms margin)
    //    within ±15 ms of the rhythmic lag, paying for straying from it.
    func correlation(_ end: Int, margin: Int) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for channel in audio.channels {
            for k in -(crossfade + margin)..<margin {
                let u = Double(channel[start + k]), v = Double(channel[end + k])
                dot += u * v
                na += u * u
                nb += v * v
            }
        }
        return dot / max(sqrt(na * nb), 1e-12)
    }
    let nominal = Int((Double(start) + lag).rounded())
    let margin = Int(0.01 * sr), waveSearch = Int(waveSearchSeconds * sr)
    let end = (-waveSearch...waveSearch).max { d1, d2 in
        let s1 = correlation(nominal + d1, margin: margin) - 0.5 * pow(Double(d1) / (strayScaleSeconds * sr), 2)
        let s2 = correlation(nominal + d2, margin: margin) - 0.5 * pow(Double(d2) / (strayScaleSeconds * sr), 2)
        return s1 < s2
    }.map { nominal + $0 } ?? nominal
    // The crossfade's gain law adapts to how alike the two sides are.
    let rho = Float(max(0, min(1, correlation(end, margin: 0))))
    log.append(String(format: "splice: rhythm %+.1f ms (r %.2f), waveform %+.1f ms, crossfade correlation %.2f",
                      rhythm.shift * Double(fineHopSamples) / sr * 1000, rhythm.r, Double(end - nominal) / sr * 1000, rho))
    return Splice(start: start, end: end, crossfade: crossfade, correlation: rho)
}

// MARK: - Loops file

func readLoops(_ loopsURL: URL) -> [String: [String: Any]] {
    guard let data = try? Data(contentsOf: loopsURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return [:] }
    return json
}

/// Writes loops.json with a stable key order and short numbers.
func writeLoops(_ loops: [String: [(String, Any)]], order: [String], to loopsURL: URL) throws {
    func value(_ v: Any) -> String {
        switch v {
        case let i as Int: return String(i)
        case let d as Double: return d == d.rounded() && abs(d) < 1e9 ? String(Int(d)) : String(format: "%.3f", d).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        case let s as String: return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        default: return "null"
        }
    }
    let names = order.filter { loops[$0] != nil } + loops.keys.filter { !order.contains($0) }.sorted()
    let body = names.map { name in
        let fields = loops[name, default: []].map { "    \(value($0.0)): \(value($0.1))" }.joined(separator: ",\n")
        return "  \(value(name)): {\n\(fields)\n  }"
    }.joined(separator: ",\n")
    try "{\n\(body)\n}\n".write(to: loopsURL, atomically: true, encoding: .utf8)
}

func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

func entry(for t: TrackAnalysis) -> [(String, Any)] {
    let sr = t.sampleRate
    let beats = t.loop.b - t.loop.a
    let basis = t.loop.basis == "around" ? "the \(straddleBars) bars either side of the seam match" : "the \(contextBars) bars \(t.loop.basis) the seam match"
    return [
        ("loopStart", t.splice.start),
        ("loopEnd", t.splice.end),
        ("crossfadeFrames", t.splice.crossfade),
        ("crossfadeCorrelation", round3(Double(t.splice.correlation))),
        ("sampleRate", Int(sr)),
        ("masterFrames", t.frameCount),
        ("loopStartSeconds", round3(Double(t.splice.start) / sr)),
        ("loopEndSeconds", round3(Double(t.splice.end) / sr)),
        ("bpm", round3(t.bpm)),
        ("beatsPerBar", t.beatsPerBar),
        ("loopBeats", beats),
        ("loopBars", round3(Double(beats) / Double(t.beatsPerBar))),
        ("introEndSeconds", round3(t.beatSamples[t.introEndBeat] / sr)),
        ("endingStartSeconds", round3(t.beatSamples[min(t.endingStartBeat, t.beatSamples.count - 1)] / sr)),
        ("similarity", round3(Double(t.loop.score))),
        ("seamContext", round3(Double(t.loop.context))),
        ("note", ([basis] + t.notes).joined(separator: "; ")),
    ]
}

// MARK: - Check

/// Renders `segments` of `url` back to back through an AVAudioPlayerNode, as
/// AudioManager schedules them.
func renderSegments(_ url: URL, _ segments: [(start: Int, count: Int)]) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()
    for segment in segments {
        player.scheduleSegment(file, startingFrame: AVAudioFramePosition(segment.start), frameCount: AVAudioFrameCount(segment.count), at: nil)
    }
    player.play()
    var remaining = segments.reduce(0) { $0 + $1.count }
    var out = [[Float]](repeating: [], count: Int(format.channelCount))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { throw fail("Cannot allocate render buffer") }
    while remaining > 0 {
        guard try engine.renderOffline(AVAudioFrameCount(min(4096, remaining)), to: buffer) == .success, let data = buffer.floatChannelData else { break }
        for c in out.indices { out[c] += UnsafeBufferPointer(start: data[c], count: Int(buffer.frameLength)) }
        remaining -= Int(buffer.frameLength)
    }
    engine.stop()
    return out
}

func rmsDB(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return -120 }
    return 10 * log10(max(x.reduce(0) { $0 + $1 * $1 } / Float(x.count), 1e-12))
}

/// Log-mel spectral flux (mean dB rise over 40 bands, 10 ms apart) every 2.5 ms over `range`.
func fluxCurve(_ x: [Float], sampleRate: Double, range: Range<Int>) -> [Float] {
    let spec = melSpectrogram(x, sampleRate: sampleRate, fftSize: 1024, hop: Int(sampleRate * 0.0025), bands: 40, range: range)
    return spectralFlux(spec.db, frames: spec.frames, bands: 40, lag: 4, floor: -100)
}

/// Strongest flux within ±`radius` samples of `centre`.
func fluxAround(_ x: [Float], sampleRate: Double, centre: Int, radius: Int) -> Float {
    let hop = Int(sampleRate * 0.0025)
    let lower = max(0, centre - radius - 2048)
    let flux = fluxCurve(x, sampleRate: sampleRate, range: lower..<min(x.count, centre + radius + 2048))
    return flux[max(0, (centre - radius - lower) / hop)...min(flux.count - 1, (centre + radius - lower) / hop)].max() ?? 0
}

func check(_ settings: Settings, seamDir: URL?) throws {
    let loops = readLoops(settings.loops)
    var failures = 0
    print("""
    offset: decoded m4a against the master (frames); tail: the file runs on past loopEnd with the loop start's audio; player: AVAudioPlayerNode renders of
    [0, end) + [start, …) and [start, end) + [start, …) match the decoded file. Seams, 4 s each side as the player joins them:
    |Δ| sample jump at the seam (p99 of local jumps; the master's own jump into A); RMS step 10 ms before → after (the
    master's step into A); dip / bump: worst 10 ms RMS below / above both natural transitions (into A, out of B) from -80 to
    +20 ms; flux: strongest log-mel flux within ±30 ms of the seam / of the master's transition into A / median beat onset
    in the loop (dB); grid: beat-grid offset of the 2 s heard before the seam against the master's 2 s before A, and of the
    2 s heard after it against the master's 2 s after B (onset correlation r; a low r means that side's rhythm differs).
    track         offset tail player  |Δ| seam (p99, natural)          RMS step              dip / bump    flux seam/natural/beat   grid before          grid after
    """)
    for track in settings.tracks {
        let (master, resource) = (track.master, track.resource)
        guard let loop = loops[master], let start = loop["loopStart"] as? Int, let end = loop["loopEnd"] as? Int else {
            print("\(master): no loop in loops.json")
            failures += 1
            continue
        }
        let m4aURL = settings.music.appendingPathComponent("\(resource).m4a")
        let masterURL = track.file
        guard FileManager.default.fileExists(atPath: m4aURL.path) else {
            print("\(master): missing \(resource).m4a")
            failures += 1
            continue
        }
        let decoded = try loadAudio(m4aURL)
        let sr = decoded.sampleRate
        let masterLength = Int(try AVAudioFile(forReading: masterURL).length)

        // Encoder delay: cross-correlate a window mid-loop against the master.
        let probe = Int(sr * 0.5), search = 4096
        let mid = start + (end - start) / 2
        let reference = try loadAudio(masterURL, frames: (mid - search)..<(mid + probe + search)).mono
        let m = decoded.mono
        let offset = (-search...search).max { o1, o2 in
            func rho(_ o: Int) -> Double {
                var dot = 0.0, na = 0.0, nb = 0.0
                for k in stride(from: 0, to: probe, by: 2) {
                    let u = Double(m[mid + k]), v = Double(reference[search + k + o])
                    dot += u * v
                    na += u * u
                    nb += v * v
                }
                return dot / max(sqrt(na * nb), 1e-12)
            }
            return rho(o1) < rho(o2)
        } ?? 0

        // Seams rendered through the player: first pass [0, end) then [start, …),
        // and loop to loop [start, end) then [start, …).
        let side = Int(4 * sr), short = Int(0.5 * sr)
        let firstPass = try renderSegments(m4aURL, [(0, end), (start, side)])
        let loopToLoop = try renderSegments(m4aURL, [(start, end - start), (start, short)])
        var joined: [[Float]] = []
        var playerError: Float = 0
        for c in decoded.channels.indices {
            let heard = Array(firstPass[c][(end - side)..<(end + side)])
            let expected = Array(decoded.channels[c][(end - side)..<end]) + Array(decoded.channels[c][start..<(start + side)])
            let again = Array(loopToLoop[c][(end - start - short)..<(end - start + short)])
            let expectedAgain = Array(decoded.channels[c][(end - short)..<end]) + Array(decoded.channels[c][start..<(start + short)])
            let firstError: Float = zip(heard, expected).map { abs($0 - $1) }.max() ?? 1
            let repeatError: Float = zip(again, expectedAgain).map { abs($0 - $1) }.max() ?? 1
            playerError = max(playerError, firstError, repeatError)
            joined.append(heard)
        }
        if let seamDir { try writeWAV(seamDir.appendingPathComponent("\(resource)-seam.wav"), channels: joined, sampleRate: sr) }

        // Metrics, against the master's own transitions into A and out of B.
        let seam = side
        let mono = vDSP.multiply(0.5, vDSP.add(joined[0], joined[joined.count - 1]))
        let intoA = try loadAudio(masterURL, frames: (start - side)..<(start + side))
        let outOfB = end + side <= masterLength ? try loadAudio(masterURL, frames: (end - side)..<(end + side)) : nil
        var jump: Float = 0, naturalJump: Float = 0, deltas: [Float] = []
        for c in joined.indices {
            jump = max(jump, abs(joined[c][seam] - joined[c][seam - 1]))
            naturalJump = max(naturalJump, abs(intoA.channels[c][seam] - intoA.channels[c][seam - 1]))
            let local = Int(0.05 * sr)
            for k in (seam - local)..<(seam + local) where k != seam { deltas.append(abs(joined[c][k] - joined[c][k - 1])) }
        }
        let tenMs = Int(0.01 * sr)
        func envelope(_ x: [Float]) -> [Float] { (-8..<2).map { rmsDB(x[(seam + $0 * tenMs)..<(seam + ($0 + 1) * tenMs)]) } }
        let heardEnvelope = envelope(mono), aEnvelope = envelope(intoA.mono), bEnvelope = outOfB.map { envelope($0.mono) } ?? aEnvelope
        let dip = heardEnvelope.indices.map { min(aEnvelope[$0], bEnvelope[$0]) - heardEnvelope[$0] }.max() ?? 0
        let bump = heardEnvelope.indices.map { heardEnvelope[$0] - max(aEnvelope[$0], bEnvelope[$0]) }.max() ?? 0
        let radius = Int(0.03 * sr)
        let seamFlux = fluxAround(mono, sampleRate: sr, centre: seam, radius: radius)
        let naturalFlux = fluxAround(intoA.mono, sampleRate: sr, centre: seam, radius: radius)
        let beat = Int(60 / (loop["bpm"] as? Double ?? 120) * sr)
        let loopFlux = fluxCurve(decoded.mono, sampleRate: sr, range: start..<(start + min(end - start, 64 * beat)))
        let perBeat = beat / Int(sr * 0.0025)
        let beatFlux = median(stride(from: 0, to: loopFlux.count - perBeat, by: perBeat).map { loopFlux[$0..<($0 + perBeat)].max() ?? 0 })
        // Beat grid either side of the seam, on 1 ms onset envelopes weighted toward the seam.
        let span = Int(2 * sr), guardBand = Int(0.06 * sr)
        func grid(_ heard: Range<Int>, against natural: [Float], towardEnd: Bool) -> (ms: Double, r: Double) {
            let h = fineOnset(mono, sampleRate: sr, range: heard), o = fineOnset(natural, sampleRate: sr, range: heard)
            let count = min(h.count, o.count), maxShift = Int(0.03 * sr) / fineHopSamples
            let result = alignment(o, h, aCentre: 0, bCentre: 0, frames: maxShift..<(count - maxShift), maxShift: maxShift) { k in
                towardEnd ? Double(k) / Double(count) : 1 - Double(k) / Double(count)
            }
            return (result.shift * Double(fineHopSamples) / sr * 1000, result.r)
        }
        let gridBefore = grid((seam - span)..<(seam - guardBand), against: intoA.mono, towardEnd: true)
        let gridAfter = outOfB.map { grid((seam + guardBand)..<(seam + span), against: $0.mono, towardEnd: false) }

        // The file runs on past the loop end with the loop start's audio (see
        // `cutLoop` in lib.js): its first half, against the master's audio at
        // the start, may differ by no more than the codec's own noise there
        // (the decoded file against the master at the start) plus 6 dB, and
        // never by more than -12 dB. The
        // codec noise is the yardstick because the two copies sit at different
        // phases of the AAC frames: a dense passage can code at -20 dB where
        // the rest of the track codes at -30, while other audio is near 0 dB.
        let tail = (decoded.count - end) / 2
        var tailOK = false
        if tail > 0 {
            let reference = try loadAudio(masterURL, frames: start..<(start + tail)).mono
            let level = rmsDB(ArraySlice(reference))
            let tailError = rmsDB(ArraySlice(vDSP.subtract(decoded.mono[end..<(end + tail)], reference))) - level
            let codecError = rmsDB(ArraySlice(vDSP.subtract(decoded.mono[start..<(start + tail)], reference))) - level
            tailOK = tailError < min(-12, codecError + 6)
        }
        let ok = offset == 0 && tailOK && playerError < 1e-4
        if !ok { failures += 1 }
        print(String(format: "%@ %5d  %@  %@   %.3f (%.3f, natural %.3f)   %+5.1f dB (natural %+5.1f)   %4.1f / %4.1f dB   %5.1f / %5.1f / %5.1f   %+5.1f ms (r %.2f)   %@",
                     resource.padding(toLength: 13, withPad: " ", startingAt: 0), offset, tailOK ? "ok " : "BAD",
                     playerError < 1e-4 ? "exact " : "DIFFER", jump, percentile(deltas, 0.99), naturalJump,
                     heardEnvelope[8] - heardEnvelope[7], aEnvelope[8] - aEnvelope[7], max(0, dip), max(0, bump),
                     seamFlux, naturalFlux, beatFlux, gridBefore.ms, gridBefore.r,
                     gridAfter.map { String(format: "%+5.1f ms (r %.2f)", $0.ms, $0.r) } ?? "-"))
    }
    if failures > 0 { throw fail("\(failures) track(s) failed the check") }
}

// MARK: - Debug image

/// Beat self-similarity (smoothed along diagonals) with the loudness per beat
/// on top, a line every `grid.every` beats, intro/ending in green and the
/// loop points in red.
func writeSimilarityImage(_ url: URL, sim: [Float], count n: Int, loudness: [Float], loop: [Int], bounds: [Int], grid: (phase: Int, every: Int)) {
    let scale = 2, strip = 50
    let width = n * scale, height = n * scale + strip
    var px = [UInt8](repeating: 255, count: width * height * 4)
    func put(_ x: Int, _ y: Int, _ rgb: (UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let o = (y * width + x) * 4
        (px[o], px[o + 1], px[o + 2], px[o + 3]) = (rgb.0, rgb.1, rgb.2, 255)
    }
    var smooth = [Float](repeating: 0, count: n * n)
    for i in 0..<n {
        for j in 0..<n {
            let ks = (-4..<4).filter { i + $0 >= 0 && j + $0 >= 0 && i + $0 < n && j + $0 < n }
            smooth[i * n + j] = ks.map { sim[(i + $0) * n + j + $0] }.reduce(0, +) / Float(ks.count)
        }
    }
    let lo = percentile(smooth, 0.6), hi = percentile(smooth, 0.995)
    let top = loudness.max() ?? 0
    for i in 0..<n {
        for y in 0..<Int(Float(strip - 4) * max(0, (loudness[i] - (top - 40)) / 40)) {
            for dx in 0..<scale { put(i * scale + dx, strip - 1 - y, (60, 60, 160)) }
        }
    }
    for y in 0..<(n * scale) {
        for x in 0..<(n * scale) {
            let g = UInt8(255 * (1 - max(0, min(1, (smooth[(y / scale) * n + x / scale] - lo) / (hi - lo)))))
            put(x, y + strip, (g, g, g))
        }
    }
    for k in stride(from: grid.phase, to: n, by: grid.every) {
        for t in stride(from: 0, to: n * scale, by: 3) {
            put(k * scale, t + strip, (255, 170, 170))
            put(t, k * scale + strip, (255, 170, 170))
        }
    }
    for (beat, rgb) in bounds.map({ ($0, (UInt8(0), UInt8(160), UInt8(0))) }) + loop.map({ ($0, (UInt8(230), UInt8(0), UInt8(0))) }) {
        for t in 0..<height { put(beat * scale, t, rgb) }
        for t in 0..<width { put(t, beat * scale + strip, rgb) }
    }
    px.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
let checking = arguments.first == "check"
if checking { arguments.removeFirst() }
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(i...(i + 1)) }
    return arguments[i + 1]
}
let only = option("--only")
let debugDir = option("--debug").map { URL(fileURLWithPath: $0) }
let seamDir = option("--seams").map { URL(fileURLWithPath: $0) }
guard let settingsPath = option("--settings") else {
    FileHandle.standardError.write(Data("find-loops: run it through music.js, which passes --settings\n".utf8))
    exit(2)
}
let settings: Settings
do {
    settings = try Settings(contentsOf: URL(fileURLWithPath: settingsPath))
} catch {
    FileHandle.standardError.write(Data("find-loops: \(error.localizedDescription)\n".utf8))
    exit(2)
}
// Checkouts may leave LFS files as pointers until they're downloaded.
for track in settings.tracks {
    let head = (try? FileHandle(forReadingFrom: track.file))?.readData(ofLength: 7) ?? Data()
    if String(decoding: head, as: UTF8.self) == "version" {
        FileHandle.standardError.write(Data("\(track.file.lastPathComponent) is a Git LFS pointer: download it first (git lfs pull)\n".utf8))
        exit(1)
    }
}

do {
    for dir in [debugDir, seamDir].compactMap({ $0 }) { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    if checking {
        try check(settings, seamDir: seamDir)
    } else {
        let tracks = settings.tracks
        // Entries kept from an earlier run (with --only) keep the field order.
        let fieldOrder = ["loopStart", "loopEnd", "crossfadeFrames", "crossfadeCorrelation", "sampleRate", "masterFrames", "loopStartSeconds", "loopEndSeconds",
                          "bpm", "beatsPerBar", "loopBeats", "loopBars", "introEndSeconds", "endingStartSeconds", "similarity", "seamContext", "note"]
        var loops = readLoops(settings.loops).mapValues { entry in
            entry.sorted { (fieldOrder.firstIndex(of: $0.key) ?? 99, $0.key) < (fieldOrder.firstIndex(of: $1.key) ?? 99, $1.key) }.map { ($0.key, $0.value) }
        }
        if let only, !tracks.contains(where: { $0.master == only }) { throw fail("No track \"\(only)\"") }
        for track in tracks where only == nil || only == track.master {
            let master = track.master
            let t = try analyze(name: master, url: track.file, minLoopSeconds: track.minLoopSeconds, debugDir: debugDir)
            loops[master] = entry(for: t)
            let sr = t.sampleRate
            print(String(format: "%@ %6.2f BPM  intro %6.2fs  loop %7.3fs → %7.3fs (%6.2f bars)  ending %6.2fs  match %.2f (%@)%@",
                         master.padding(toLength: 13, withPad: " ", startingAt: 0), t.bpm, t.beatSamples[t.introEndBeat] / sr,
                         Double(t.splice.start) / sr, Double(t.splice.end) / sr, Double(t.loop.b - t.loop.a) / Double(t.beatsPerBar),
                         t.beatSamples[min(t.endingStartBeat, t.beatSamples.count - 1)] / sr, t.loop.score, t.loop.basis,
                         t.notes.isEmpty ? "" : "  [" + t.notes.joined(separator: "; ") + "]"))
        }
        try writeLoops(loops, order: tracks.map(\.master), to: settings.loops)
    }
} catch {
    FileHandle.standardError.write("find-loops: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
