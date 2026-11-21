// Records one window to a QuickTime movie with ScreenCaptureKit, at up to
// 60 fps, and prints the wall-clock time its first frame showed
// ("first-frame <seconds since 1970>"), so anything stamped by the same clock
// (the game's markers) lines up with the picture to the frame, however long
// the capture took to start. It stops after `seconds`, or sooner on SIGTERM,
// writing its file either way. Built and run by apple.js (`macRecorder`):
//
//   mac-record <window id> <seconds> <file.mov>
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private(set) var last = CMTime.invalid
    // Frames ScreenCaptureKit sent, those that held a new picture, and those written.
    private(set) var sent = 0, fresh = 0, written = 0

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid else { return }
        sent += 1
        guard let infos = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        fresh += 1
        let time = buffer.presentationTimeStamp
        if !started {
            // The movie starts at this frame.
            started = true
            writer.startSession(atSourceTime: time)
            // The frame's time is on the host clock; the markers', the wall clock's.
            let ago = (CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds
            print(String(format: "first-frame %.4f", Date().timeIntervalSince1970 - ago))
            fflush(stdout)
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(buffer)
        written += 1
        last = time
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("the capture stopped: \(error.localizedDescription)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac-record: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let windowID = CGWindowID(arguments[1]), let seconds = Double(arguments[2]) else {
    fail("usage: mac-record <window id> <seconds> <file.mov>")
}
let url = URL(fileURLWithPath: arguments[3])
let queue = DispatchQueue(label: "mac-record")
// ScreenCaptureKit needs the window server, which a command-line tool only
// reaches once it's an application (one with no Dock icon or menu).
NSApplication.shared.setActivationPolicy(.prohibited)

// SIGTERM ends the recording early.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}
let stop = Flag()
signal(SIGTERM, SIG_IGN)
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { stop.raise() }
terminate.resume()

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { fail("no window \(windowID) on screen") }
        // The display it's on, showing it alone and cropped to it: a window's
        // own capture comes at 30 fps at most, a display's at its refresh rate.
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }) else {
            fail("window \(windowID) is on no display")
        }
        let filter = SCContentFilter(display: display, including: [window])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 8
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { fail("can't write \(url.path): \(writer.error?.localizedDescription ?? "")") }

        let recorder = Recorder(writer: writer, input: input)
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !stop.isRaised { try await Task.sleep(nanoseconds: 20_000_000) }
        try await stream.stopCapture()
        let (last, sent, fresh, written) = queue.sync { (recorder.last, recorder.sent, recorder.fresh, recorder.written) }
        guard last.isValid else { fail("no frames came") }
        print("frames \(sent) sent, \(fresh) new, \(written) written")
        fflush(stdout)
        input.markAsFinished()
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
        guard writer.status == .completed else { fail("writing failed: \(writer.error?.localizedDescription ?? "")") }
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}
dispatchMain()
