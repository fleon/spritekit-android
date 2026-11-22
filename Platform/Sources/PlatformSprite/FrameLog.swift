import Foundation
import SpriteKitShim

/// Notes when every frame renders for `duration` seconds, with the scene on
/// screen, then writes them to `Library/Caches/frames.json` (seconds since
/// the first frame), to graph the frame rate on a device without
/// Instruments. Set it as the view's delegate.
public final class FrameLog: NSObject, SKViewDelegate {
    private let duration: TimeInterval
    private var start: TimeInterval?
    private var times: [Double] = []
    private var scenes: [[String: Any]] = []
    private var lastScene: ObjectIdentifier?
    private var isDone = false
    private let fileName: String

    /// `capacityPerSecond`: frames a second to make room for up front.
    public init(duration: TimeInterval, capacityPerSecond: Int = 120, fileName: String = "frames.json") {
        self.duration = duration
        self.fileName = fileName
        times.reserveCapacity(Int(duration * Double(capacityPerSecond)))
    }

    public func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        guard !isDone else { return true }
        let start = start ?? time
        self.start = start
        let elapsed = time - start
        if let scene = view.scene, ObjectIdentifier(scene) != lastScene {
            lastScene = ObjectIdentifier(scene)
            scenes.append(["t": elapsed, "scene": String(describing: type(of: scene))])
        }
        times.append(elapsed)
        if elapsed >= duration { write() }
        return true
    }

    private func write() {
        isDone = true
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: ["frames": times, "scenes": scenes]) else { return }
        try? data.write(to: caches.appendingPathComponent(fileName))
    }
}
