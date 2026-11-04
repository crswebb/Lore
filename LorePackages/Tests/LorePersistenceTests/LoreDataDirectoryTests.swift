import Foundation
import XCTest
@testable import LorePersistence

final class LoreDataDirectoryTests: XCTestCase {
    func testNoOverrideWhenUnset() {
        XCTAssertNil(LoreDataDirectory.overrideURL(environment: [:]))
    }

    func testBlankOverrideIsIgnored() {
        XCTAssertNil(LoreDataDirectory.overrideURL(environment: ["LORE_DATA_DIR": "   "]))
    }

    func testOverrideExpandsTilde() {
        let url = LoreDataDirectory.overrideURL(environment: ["LORE_DATA_DIR": "~/lore-dev"])
        XCTAssertEqual(url?.path, (NSHomeDirectory() as NSString).appendingPathComponent("lore-dev"))
    }

    func testOverrideIsCreatedAndUsedForDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-data-dir-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = try LoreDataDirectory.url(environment: ["LORE_DATA_DIR": dir.path])
        XCTAssertEqual(resolved.standardizedFileURL.path, dir.standardizedFileURL.path)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let dbURL = try LoreDatabase.defaultURL(environment: ["LORE_DATA_DIR": dir.path])
        XCTAssertEqual(dbURL.deletingLastPathComponent().standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertEqual(dbURL.lastPathComponent, "lore.sqlite")
    }
}
