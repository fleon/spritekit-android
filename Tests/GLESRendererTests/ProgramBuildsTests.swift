import Foundation
import Testing
@testable import GLESRenderer
@testable import SpriteKitShim

@Suite("Program builds", .timeLimit(.minutes(1)))
struct ProgramBuildsTests {
    final class Builder: @unchecked Sendable {
        let lock = NSLock()
        var built: [String] = []
        let gate = DispatchSemaphore(value: 0)
    }

    @Test("A program is built once on the builder, and taking it waits for the build")
    func buildsOnceAndWaits() {
        let builder = Builder()
        let queue = DispatchQueue(label: "builder")
        let builds = ProgramBuilds(schedule: { queue.async(execute: $0) }) { _, fragment in
            builder.gate.wait()
            builder.lock.lock(); builder.built.append(fragment); builder.lock.unlock()
            return fragment == "bad" ? 0 : 7
        }
        builds.submit(key: "k", vertex: "v", fragment: "f")
        builds.submit(key: "k", vertex: "v", fragment: "f")
        builds.submit(key: "x", vertex: "v", fragment: "bad")
        #expect(builds.knows("k"))
        builder.gate.signal()
        builder.gate.signal()
        #expect(builds.take("k") == 7)
        #expect(builds.take("x") == nil, "a failed build is the frame thread's to try again")
        #expect(builder.built == ["f", "bad"])
        // Held once taken: never built again.
        builds.submit(key: "k", vertex: "v", fragment: "f")
        #expect(builds.take("k") == nil)
        #expect(builder.built.count == 2)
    }

    @Test("Shaders handed over build ahead, and the cache takes their programs")
    func cacheTakesBuilt() {
        let device = RecordingDevice()
        let cache = ResourceCache(device: device)
        let queue = DispatchQueue(label: "builder")
        let builds = ProgramBuilds(schedule: { queue.async(execute: $0) }) { _, _ in 42 }
        cache.programBuilds = builds
        let shader = SKShader(source: "void main() { gl_FragColor = vec4(u_a); }", uniforms: [SKUniform(name: "u_a", float: 1)])
        ResourceCache.buildAhead([shader], in: builds)
        #expect(cache.program(for: shader) == 42)
        #expect(device.programs.isEmpty)
        // One the builder never saw is linked here, and not built there after.
        let other = SKShader(source: "void main() { gl_FragColor = vec4(0.0); }")
        let local = cache.program(for: other)
        #expect(local != 0 && device.programs.count == 1)
        #expect(builds.knows(ResourceCache.programKey(for: other)))
    }
}
