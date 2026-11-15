import CAndroidShell
import Foundation

/// Writes a frame's batches into its mapped vertex and index buffers, one
/// after another (`SceneRenderer.stage`), each draw's 16-bit indices moved
/// on by where its vertices start, as 32-bit indices from the buffer's
/// start. Where a buffer would not map, what it would have held is written
/// here and copied in as the stream finishes.
struct StreamWriter {
    private var vertices: UnsafeMutableRawPointer?
    private var indices: UnsafeMutableRawPointer?
    private let mappedVertices: Bool
    private let mappedIndices: Bool
    private var vertexOffset = 0
    private var indexCount = 0

    init(vertices: UnsafeMutableRawPointer?, indices: UnsafeMutableRawPointer?, vertexBytes: Int, indexCount: Int) {
        mappedVertices = vertices != nil
        mappedIndices = indices != nil
        self.vertices = vertices ?? UnsafeMutableRawPointer.allocate(byteCount: vertexBytes, alignment: 16)
        self.indices = indices ?? UnsafeMutableRawPointer.allocate(byteCount: indexCount * 4, alignment: 16)
        self.capacity = (vertexBytes, indexCount)
    }

    private let capacity: (vertexBytes: Int, indexCount: Int)

    /// Adds one draw; hands back where its indices start, in indices.
    mutating func add(_ vertexData: [Float], _ indexData: [UInt16]) -> Int {
        let bytes = vertexData.count * MemoryLayout<Float>.size
        precondition(vertexOffset + bytes <= capacity.vertexBytes && indexCount + indexData.count <= capacity.indexCount,
                     "a staged frame outgrew what it measured")
        let base = UInt32(vertexOffset / SceneRenderer.vertexStride)
        vertexData.withUnsafeBytes { source in
            if let from = source.baseAddress, let vertices { (vertices + vertexOffset).copyMemory(from: from, byteCount: bytes) }
        }
        if let indices { Self.rebase(indexData, by: base, into: indices + indexCount * 4) }
        let first = indexCount
        vertexOffset += bytes
        indexCount += indexData.count
        return first
    }

    /// Unmaps the buffers, or copies in what couldn't be mapped.
    mutating func finish(vertexTarget: GLenum, indexTarget: GLenum) {
        if mappedVertices {
            glUnmapBuffer(vertexTarget)
        } else if let vertices {
            glBufferSubData(vertexTarget, 0, vertexOffset, vertices)
            vertices.deallocate()
        }
        if mappedIndices {
            glUnmapBuffer(indexTarget)
        } else if let indices {
            glBufferSubData(indexTarget, 0, indexCount * 4, indices)
            indices.deallocate()
        }
        vertices = nil
        indices = nil
    }

    static func rebase(_ source: [UInt16], by base: UInt32, into destination: UnsafeMutableRawPointer) {
        let out = destination.bindMemory(to: UInt32.self, capacity: source.count)
        source.withUnsafeBufferPointer { from in
            for index in 0 ..< from.count { out[index] = UInt32(from[index]) &+ base }
        }
    }
}
