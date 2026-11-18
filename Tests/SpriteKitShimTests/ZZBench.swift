import Foundation
import Darwin
func cpuNow() -> Double { var t = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
import Testing
import CoreGraphics
@testable import SpriteKitShim

@Suite("Bench") struct Bench {
    @Test func dashed() {
        let rect = CGRect(x: -180, y: -60, width: 360, height: 120)
        let base = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        let scale: CGFloat = 2.625
        var tDash = 0.0, tFlat = 0.0, tOut = 0.0, tCov = 0.0
        let n = 400
        for i in 0..<n {
            var t0 = cpuNow()
            let dashed = base.copy(dashingWithPhase: CGFloat(i) * 0.23, lengths: [8, 6])
            tDash += cpuNow() - t0; t0 = cpuNow()
            let sub = PathRasteriser.flatten(dashed, scale: scale)
            tFlat += cpuNow() - t0; t0 = cpuNow()
            let outlines = PathRasteriser.strokeOutlines(sub, width: 2, cap: .butt, join: .miter, miterLimit: 10)
            tOut += cpuNow() - t0; t0 = cpuNow()
            let mask = PathRasteriser.rasterise(outlines, rule: .nonZero, scale: scale)
            tCov += cpuNow() - t0
            if i == 0 {
                var edgeRows = 0, polys = 0
                for o in outlines { polys += o.count
                    for j in 0..<o.count { let a = o[j], b = o[(j+1)%o.count]; edgeRows += Int(abs(a.y-b.y)*scale) + 1 } }
                print("BENCH edge-rows \(edgeRows) points \(polys)")
                print("BENCH subpaths \(sub.count) outlines \(outlines.count) mask \(mask?.width ?? 0)x\(mask?.height ?? 0)") }
        }
        var tEmpty = 0.0
        for _ in 0..<n { let t0 = cpuNow(); _ = [UInt8](repeating: 0, count: 953 * 323); tEmpty += cpuNow() - t0 }
        print(String(format: "BENCH alloc only %.3f", tEmpty / Double(n) * 1000))
        print(String(format: "BENCH per frame ms: dash %.2f flatten %.2f outline %.2f coverage %.2f", tDash/Double(n)*1000, tFlat/Double(n)*1000, tOut/Double(n)*1000, tCov/Double(n)*1000))
    }
}
