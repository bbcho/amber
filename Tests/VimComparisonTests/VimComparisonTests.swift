import Foundation
import XCTest

/// Runs every corpus case through real Vim and through the engine and compares text and
/// cursor. A mismatch is allowed only for a case named in `KnownDifferences.md`, and a listed
/// case that now matches is an error too, so the list never goes stale.
final class VimComparisonTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: RealVim.path),
                          "\(RealVim.path) is not installed, so the comparison with real Vim "
                          + "is skipped")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amber-vim-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// The case names under "## Corpus exceptions" in `KnownDifferences.md`, written as
    /// `- \`name\`: reason`.
    private func listedDifferences() throws -> [String: String] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("KnownDifferences.md")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        var listed: [String: String] = [:]
        var inSection = false
        for line in lines {
            if line.hasPrefix("## ") { inSection = line == "## Corpus exceptions" }
            guard inSection, line.hasPrefix("- `"),
                  let close = line.dropFirst(3).firstIndex(of: "`") else { continue }
            listed[String(line[line.index(line.startIndex, offsetBy: 3)..<close])] =
                String(line[close...])
        }
        return listed
    }

    func test_the_engine_matches_real_vim_on_every_case_except_the_listed_differences() throws {
        let listed = try listedDifferences()
        let vim = RealVim(directory: directory)
        var matched = 0
        var seenDifferences: Set<String> = []
        for testCase in vimCorpus {
            let context = "\(testCase.name): keys \(testCase.keys) on "
                + testCase.before.debugDescription
            let expected: VimOutcome
            let actual: VimOutcome
            do {
                expected = try vim.run(testCase)
                actual = try AmberEngine.run(testCase)
            } catch {
                XCTFail("\(context)\n\(error)")
                continue
            }
            if actual == expected {
                matched += 1
                XCTAssertNil(listed[testCase.name],
                             "\(testCase.name) is listed as a difference but now matches Vim")
            } else if listed[testCase.name] != nil {
                seenDifferences.insert(testCase.name)
            } else {
                XCTFail("\(context)\nVim:   \(expected)\nAmber: \(actual)")
            }
        }
        let names = Set(vimCorpus.map(\.name))
        XCTAssertEqual(listed.keys.filter { !names.contains($0) }.sorted(), [],
                       "KnownDifferences.md lists cases that are not in the corpus")
        XCTAssertEqual(matched + seenDifferences.count, vimCorpus.count)
    }

    func test_the_corpus_has_at_least_150_cases_with_unique_names() {
        XCTAssertGreaterThanOrEqual(vimCorpus.count, 150)
        XCTAssertEqual(Set(vimCorpus.map(\.name)).count, vimCorpus.count)
    }

    func test_the_corpus_covers_every_command_family() {
        let families = Set(vimCorpus.map { String($0.name.prefix { $0 != "/" }) })
        XCTAssertEqual(families, [
            "motion", "count", "operator", "textobject", "register", "put", "edit", "dot",
            "visual", "block", "insert", "replace", "search", "macro", "mark", "ex", "option",
        ])
    }
}
