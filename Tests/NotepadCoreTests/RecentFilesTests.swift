import Foundation
import XCTest
@testable import NotepadCore

final class RecentFilesTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/notes/\(name)") }

    func test_adding_puts_the_newest_file_first_without_duplicates() {
        let recent = RecentFiles()
            .adding(url("a.md")).adding(url("b.md")).adding(url("a.md"))
        XCTAssertEqual(recent.urls, [url("a.md"), url("b.md")])
    }

    func test_only_the_ten_most_recent_files_are_kept() {
        let recent = (1...12).reduce(RecentFiles()) { $0.adding(url("\($1).md")) }
        XCTAssertEqual(recent.urls, (3...12).reversed().map { url("\($0).md") })
    }

    func test_saving_and_loading_round_trips_through_a_file() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Recent.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let recent = RecentFiles().adding(url("a.md")).adding(url("b.md"))
        try recent.save(to: file)
        XCTAssertEqual(RecentFiles.load(from: file).urls, [url("b.md"), url("a.md")])
    }

    func test_a_missing_or_corrupt_file_loads_as_empty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("none.json")
        XCTAssertEqual(RecentFiles.load(from: missing).urls, [])
        let corrupt = directory.appendingPathComponent("Recent.json")
        try Data("not json".utf8).write(to: corrupt)
        XCTAssertEqual(RecentFiles.load(from: corrupt).urls, [])
    }
}
