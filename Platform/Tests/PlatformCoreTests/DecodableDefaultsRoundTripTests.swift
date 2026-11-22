import Foundation
import Macros
import XCTest

@DecodableDefaults
nonisolated struct DecodedProfile: Codable, Equatable {
    var name: String
    var coins = 0
    var badges: [String] = ["new"]
    var avatar: String?
    var level: Int? = 1
    var score: Int { coins * 2 }
}

@DecodableDefaults
nonisolated struct DecodedRenamed: Equatable {
    var grid: [Int]
    var seen = false

    private enum CodingKeys: String, CodingKey {
        case grid = "cells"
    }
}

@DecodableDefaults
nonisolated final class DecodedSave: Codable {
    var best: Int = 7
    var tag: String

    init(tag: String) { self.tag = tag }
}

nonisolated final class DecodedOwner {
    @DecodableDefaults
    private struct Snapshot: Codable {
        var keys: [String] = []
        var count: Int
    }

    static func snapshot(_ json: String) throws -> (keys: [String], count: Int) {
        let s = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        return (s.keys, s.count)
    }
}

final class DecodableDefaultsRoundTripTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testMissingAndNullKeysTakeTheInitialValues() throws {
        let profile = try decode(DecodedProfile.self, #"{"name": "a", "badges": null}"#)
        XCTAssertEqual(profile, DecodedProfile(name: "a", coins: 0, badges: ["new"], avatar: nil, level: 1))
    }

    func testPresentKeysWin() throws {
        let json = #"{"name": "b", "coins": 5, "badges": [], "avatar": "x", "level": 3}"#
        let profile = try decode(DecodedProfile.self, json)
        XCTAssertEqual(profile, DecodedProfile(name: "b", coins: 5, badges: [], avatar: "x", level: 3))
    }

    func testRequiredKeysStillThrow() {
        XCTAssertThrowsError(try decode(DecodedProfile.self, #"{"coins": 1}"#))
        XCTAssertThrowsError(try decode(DecodedProfile.self, #"{"name": "a", "coins": "x"}"#))
    }

    func testEncodingStaysSynthesized() throws {
        let profile = DecodedProfile(name: "c", coins: 2)
        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(DecodedProfile.self, from: data), profile)
    }

    func testDeclaredCodingKeysRenameAndSkip() throws {
        let renamed = try decode(DecodedRenamed.self, #"{"cells": [1, 2], "seen": true}"#)
        XCTAssertEqual(renamed, DecodedRenamed(grid: [1, 2], seen: false))
    }

    func testFinalClassAndNestedType() throws {
        let save = try decode(DecodedSave.self, #"{"tag": "t"}"#)
        XCTAssertEqual(save.best, 7)
        XCTAssertEqual(save.tag, "t")
        let snapshot = try DecodedOwner.snapshot(#"{"count": 4}"#)
        XCTAssertEqual(snapshot.keys, [])
        XCTAssertEqual(snapshot.count, 4)
    }
}
