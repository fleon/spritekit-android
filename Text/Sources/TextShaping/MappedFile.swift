#if canImport(CTextShaping)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif

/// A file mapped read-only into memory, as `Data` that unmaps it when the
/// last copy goes. Pages are read as they are touched, so a large font costs
/// what is drawn from it, not its size.
enum MappedFile {
    static func map(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size > 0 else { return nil }
        let length = Int(status.st_size)
        // Bionic's mmap returns a pointer, Darwin's an optional one; failure
        // is (void *)-1 on both (MAP_FAILED, which Swift doesn't import on Android).
        let mapped: UnsafeMutableRawPointer? = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let address = mapped, Int(bitPattern: address) != -1 else { return nil }
        return Data(bytesNoCopy: address, count: length, deallocator: .custom { pointer, count in
            munmap(pointer, count)
        })
    }
}
#endif
