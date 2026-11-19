#if canImport(CTextShaping)
import Foundation

/// A variable font's horizontal advance deltas (`HVAR`), evaluated in
/// floating point at one instance's normalized coordinates.
///
/// HarfBuzz applies these deltas rounded to whole font units
/// (`hmtx::get_advance_with_var_unscaled`), where Core Text keeps them
/// fractional; a line of a variable instance then measures a few hundredths
/// of a point apart. The shaper adds back each glyph's fraction
/// (`fraction(of:)`), so advances come out as Core Text's. Read straight from
/// the table (OpenType 1.9, `HVAR`, `DeltaSetIndexMap`, `ItemVariationStore`).
struct AdvanceVariations {
    private let bytes: [UInt8]
    private let coordinates: [Double]
    private let store: Int
    private let mapping: Int?

    /// Nil without an `HVAR` table, or at the default instance (every
    /// coordinate 0, where every delta is 0).
    init?(hvar: [UInt8], normalizedCoordinates: [Int32]) {
        guard hvar.count >= 20, normalizedCoordinates.contains(where: { $0 != 0 }) else { return nil }
        bytes = hvar
        coordinates = normalizedCoordinates.map { Double($0) / 16384 }
        let storeOffset = Int(Self.u32(hvar, 4))
        let mappingOffset = Int(Self.u32(hvar, 8))
        guard storeOffset > 0, storeOffset < hvar.count else { return nil }
        store = storeOffset
        mapping = mappingOffset > 0 && mappingOffset < hvar.count ? mappingOffset : nil
    }

    /// The glyph's delta less the whole font units HarfBuzz already applied.
    func fraction(of glyph: UInt32) -> Double {
        guard let delta = delta(of: glyph) else { return 0 }
        return delta - delta.rounded()   // C's roundf: halves away from zero, as HarfBuzz rounds
    }

    /// The glyph's advance delta in font units.
    func delta(of glyph: UInt32) -> Double? {
        guard let (outer, inner) = index(of: glyph) else { return nil }
        // ItemVariationStore: format, region list offset, data count, data offsets.
        guard has(store, 8) else { return nil }
        let regionList = store + Int(Self.u32(bytes, store + 2))
        let dataCount = Int(Self.u16(bytes, store + 6))
        guard outer < dataCount, has(store + 8 + outer * 4, 4), has(regionList, 4) else { return nil }
        let data = store + Int(Self.u32(bytes, store + 8 + outer * 4))
        guard has(data, 6) else { return nil }
        let itemCount = Int(Self.u16(bytes, data))
        let wordField = Int(Self.u16(bytes, data + 2))
        let regionCount = Int(Self.u16(bytes, data + 4))
        guard inner < itemCount, has(data + 6, regionCount * 2) else { return nil }
        let long = wordField & 0x8000 != 0
        let words = wordField & 0x7FFF
        let wordSize = long ? 4 : 2, shortSize = long ? 2 : 1
        let rowSize = words * wordSize + (regionCount - words) * shortSize
        let row = data + 6 + regionCount * 2 + inner * rowSize
        guard has(row, rowSize) else { return nil }
        var total = 0.0
        var cursor = row
        for column in 0 ..< regionCount {
            let value: Int
            if column < words {
                value = long ? Int(Int32(bitPattern: Self.u32(bytes, cursor))) : Int(Int16(bitPattern: Self.u16(bytes, cursor)))
                cursor += wordSize
            } else {
                value = long ? Int(Int16(bitPattern: Self.u16(bytes, cursor))) : Int(Int8(bitPattern: bytes[cursor]))
                cursor += shortSize
            }
            guard value != 0 else { continue }
            let region = Int(Self.u16(bytes, data + 6 + column * 2))
            total += Double(value) * scalar(of: region, in: regionList)
        }
        return total
    }

    /// The glyph's (outer, inner) delta-set index: the mapping's entry, the
    /// last one past its end, or (0, glyph) without a mapping.
    private func index(of glyph: UInt32) -> (Int, Int)? {
        guard let mapping else { return (0, Int(glyph)) }
        guard has(mapping, 2) else { return nil }
        let format = bytes[mapping]
        let entryFormat = Int(bytes[mapping + 1])
        let count: Int, entries: Int
        if format == 0 {
            guard has(mapping, 4) else { return nil }
            count = Int(Self.u16(bytes, mapping + 2)); entries = mapping + 4
        } else {
            guard has(mapping, 6) else { return nil }
            count = Int(Self.u32(bytes, mapping + 2)); entries = mapping + 6
        }
        guard count > 0 else { return nil }
        let size = ((entryFormat & 0x30) >> 4) + 1
        let innerBits = (entryFormat & 0x0F) + 1
        let position = entries + min(Int(glyph), count - 1) * size
        guard has(position, size) else { return nil }
        var entry = 0
        for byte in 0 ..< size { entry = entry << 8 | Int(bytes[position + byte]) }
        return (entry >> innerBits, entry & ((1 << innerBits) - 1))
    }

    /// A region's scalar at the coordinates: the product of each axis's
    /// tent, 1 at its peak and 0 outside its start and end.
    private func scalar(of region: Int, in list: Int) -> Double {
        let axes = Int(Self.u16(bytes, list))
        let regions = Int(Self.u16(bytes, list + 2))
        guard region < regions else { return 0 }
        let base = list + 4 + region * axes * 6
        guard has(base, axes * 6) else { return 0 }
        var product = 1.0
        for axis in 0 ..< axes {
            let start = Double(Int16(bitPattern: Self.u16(bytes, base + axis * 6))) / 16384
            let peak = Double(Int16(bitPattern: Self.u16(bytes, base + axis * 6 + 2))) / 16384
            let end = Double(Int16(bitPattern: Self.u16(bytes, base + axis * 6 + 4))) / 16384
            let coordinate = axis < coordinates.count ? coordinates[axis] : 0
            if peak == 0 || coordinate == peak { continue }
            if start > peak || peak > end || (start < 0 && end > 0) { continue }
            if coordinate <= start || coordinate >= end { return 0 }
            product *= coordinate < peak ? (coordinate - start) / (peak - start) : (end - coordinate) / (end - peak)
        }
        return product
    }

    private func has(_ offset: Int, _ length: Int) -> Bool { offset >= 0 && offset + length <= bytes.count }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
#endif
