import AppKit
import NotepadCore
import XCTest
@testable import AmberNotepad

final class DisplayOptionsTests: XCTestCase {
    private let cell = Phosphor.font.maximumAdvancement.width

    // MARK: Gutter

    func test_number_shows_absolute_line_numbers() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb\nc\nd\ne")
            defer { window.contentView = nil }
            set("number", in: terminal)
            XCTAssertEqual(terminal.gutter.rows.map(\.text), ["1", "2", "3", "4", "5"])
        }
    }

    func test_relativenumber_counts_distance_from_the_cursor_line() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb\nc\nd\ne")
            defer { window.contentView = nil }
            terminal.textView.feed([VimKey(.character("j")), VimKey(.character("j"))])
            set("relativenumber", in: terminal)
            XCTAssertEqual(terminal.gutter.rows.map(\.text), ["2", "1", "0", "1", "2"])
        }
    }

    func test_both_number_options_show_the_absolute_number_on_the_cursor_line() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb\nc\nd\ne")
            defer { window.contentView = nil }
            terminal.textView.feed([VimKey(.character("j")), VimKey(.character("j"))])
            set("number relativenumber", in: terminal)
            XCTAssertEqual(terminal.gutter.rows.map(\.text), ["2", "1", "3", "1", "2"])
            terminal.textView.feed([VimKey(.character("k"))])
            XCTAssertEqual(terminal.gutter.rows.map(\.text), ["1", "2", "1", "2", "3"])
        }
    }

    func test_the_gutter_lists_only_visible_lines_and_numbers_a_wrapped_line_once() async {
        await MainActor.run {
            let long = String(repeating: "word ", count: 300)
            let text = ([long] + (2...300).map { "line \($0)" }).joined(separator: "\n")
            let (terminal, window) = editorWindow(text)
            defer { window.contentView = nil }
            set("number", in: terminal)
            let top = terminal.gutter.rows.map(\.text)
            XCTAssertEqual(top.first, "1")
            XCTAssertEqual(top.filter { $0 == "1" }.count, 1)
            XCTAssertLessThan(top.count, 60)
            let clip = terminal.textView.enclosingScrollView!.contentView
            clip.scroll(to: NSPoint(
                x: 0, y: terminal.textView.frame.height - clip.bounds.height
            ))
            terminal.textView.enclosingScrollView!.reflectScrolledClipView(clip)
            XCTAssertEqual(terminal.gutter.rows.map(\.text).last, "300")
        }
    }

    func test_the_gutter_paints_amber_numbers_and_the_text_moves_right() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb")
            defer { window.contentView = nil }
            let scroll = terminal.textView.enclosingScrollView!
            XCTAssertTrue(terminal.gutter.isHidden)
            XCTAssertEqual(scroll.frame.minX, 0)
            set("number", in: terminal)
            XCTAssertFalse(terminal.gutter.isHidden)
            XCTAssertGreaterThan(terminal.gutter.frame.width, 0)
            XCTAssertEqual(scroll.frame.minX, terminal.gutter.frame.width)
            XCTAssertGreaterThan(litPixels(terminal.gutter, terminal.gutter.bounds), 0)
            set("nonumber", in: terminal)
            XCTAssertTrue(terminal.gutter.isHidden)
            XCTAssertEqual(scroll.frame.minX, 0)
        }
    }

    func test_gutter_rows_sit_level_with_their_text_lines() async {
        await MainActor.run {
            let long = String(repeating: "word ", count: 200)
            let text = ([long] + (2...200).map { "line \($0)" }).joined(separator: "\n")
            let (terminal, window) = editorWindow(text)
            defer { window.contentView = nil }
            set("number", in: terminal)
            let view = terminal.textView
            let clip = view.enclosingScrollView!.contentView
            for offset in [CGFloat(0), 1234.5] {
                clip.scroll(to: NSPoint(x: 0, y: offset))
                view.enclosingScrollView!.reflectScrolledClipView(clip)
                let rows = terminal.gutter.rows
                XCTAssertGreaterThan(rows.count, 10)
                for row in rows {
                    let line = Int(row.text)! - 1
                    let top = fragmentTop(ofLine: line, in: view, gutter: terminal.gutter)
                    XCTAssertEqual(row.y, top, accuracy: 0.01,
                                   "line \(line + 1) at scroll \(offset)")
                }
            }
        }
    }

    // MARK: List

    func test_list_draws_tab_trailing_space_and_line_end_markers_without_changing_text() async {
        await MainActor.run {
            let text = "x\ty  \nz"
            let (terminal, window) = editorWindow(text)
            defer { window.contentView = nil }
            let view = terminal.textView
            view.setSelectedRange(NSRange(location: 6, length: 0))
            let cells = [cellRect(1, in: view), cellRect(3, in: view), cellRect(4, in: view),
                         endRect(of: 0, in: view)]
            let plain = cells.map { litPixels(view, $0) }
            let before = view.undoManager?.canUndo

            set("list", in: terminal)

            XCTAssertEqual(view.string, text)
            XCTAssertEqual(view.undoManager?.canUndo, before)
            for (index, rect) in cells.enumerated() {
                XCTAssertGreaterThan(litPixels(view, rect), plain[index], "marker \(index)")
            }
            set("nolist", in: terminal)
            XCTAssertEqual(cells.map { litPixels(view, $0) }, plain)
        }
    }

    func test_list_marks_the_end_of_a_last_line_without_a_break_but_not_interior_spaces()
        async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a b\nc")
            defer { window.contentView = nil }
            let view = terminal.textView
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let interior = litPixels(view, cellRect(1, in: view))
            let end = litPixels(view, endRect(of: 1, in: view))
            set("list", in: terminal)
            XCTAssertEqual(litPixels(view, cellRect(1, in: view)), interior)
            XCTAssertGreaterThan(litPixels(view, endRect(of: 1, in: view)), end)
        }
    }

    // MARK: Cursor line

    func test_cursorline_paints_a_band_behind_the_cursor_line_that_follows_the_cursor() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb\nc")
            defer { window.contentView = nil }
            let view = terminal.textView
            let far = { (line: Int) in self.farRight(of: line, in: view) }
            XCTAssertEqual([0, 1].map { litPixels(view, far($0)) }, [0, 0])
            set("cursorline", in: terminal)
            XCTAssertGreaterThan(litPixels(view, far(0)), 0)
            XCTAssertEqual(litPixels(view, far(1)), 0)
            view.feed([VimKey(.character("j"))])
            XCTAssertEqual(litPixels(view, far(0)), 0)
            XCTAssertGreaterThan(litPixels(view, far(1)), 0)
        }
    }

    // MARK: Wrap and tabstop

    func test_nowrap_keeps_a_long_line_on_one_row_and_scrolls_horizontally() async {
        await MainActor.run {
            let (terminal, window) = editorWindow(String(repeating: "a", count: 400))
            defer { window.contentView = nil }
            let view = terminal.textView
            let scroll = view.enclosingScrollView!
            XCTAssertGreaterThan(fragmentCount(view), 1)
            set("nowrap", in: terminal)
            XCTAssertEqual(fragmentCount(view), 1)
            XCTAssertTrue(scroll.hasHorizontalScroller)
            XCTAssertGreaterThan(view.frame.width, scroll.contentSize.width)
            view.feed([VimKey(.character("$"))])
            XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
            set("wrap", in: terminal)
            XCTAssertGreaterThan(fragmentCount(view), 1)
            XCTAssertFalse(scroll.hasHorizontalScroller)
            XCTAssertEqual(view.frame.width, scroll.contentSize.width)
        }
    }

    func test_tabstop_sets_the_tab_width_on_screen_for_existing_and_new_text() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\tb")
            defer { window.contentView = nil }
            let view = terminal.textView
            XCTAssertEqual(columnX(of: 2, in: view), cell * 4, accuracy: 0.01)
            set("ts=8", in: terminal)
            XCTAssertEqual(columnX(of: 2, in: view), cell * 8, accuracy: 0.01)
            view.string = "ab\tc"
            XCTAssertEqual(columnX(of: 3, in: view), cell * 8, accuracy: 0.01)
            XCTAssertEqual(view.string, "ab\tc")
        }
    }

    // MARK: Every window, amberrc, Vim off

    func test_set_applies_the_display_options_in_every_open_window() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace()
            defer { cleanup(app, directory) }
            let first = try app.createWindow()
            let second = try app.createWindow()
            let views = [first, second].map(\.terminal.textView)
            for view in views { view.string = "a\tb\n" }
            let plain = views.map { litPixels($0, cellRect(1, in: $0)) }
            XCTAssertEqual(views.map { columnX(of: 2, in: $0) }, [cell * 4, cell * 4])

            XCTAssertTrue(app.execute("set number list ts=2", in: first))

            for (index, editor) in [first, second].enumerated() {
                XCTAssertFalse(editor.terminal.gutter.isHidden, "window \(index)")
                XCTAssertEqual(columnX(of: 2, in: views[index]), cell * 2, accuracy: 0.01)
                XCTAssertGreaterThan(
                    litPixels(views[index], cellRect(1, in: views[index])), plain[index],
                    "list marker in window \(index)"
                )
            }
        }
    }

    func test_amberrc_display_options_apply_to_windows_at_launch() async throws {
        try await MainActor.run {
            let (app, directory) = try workspace(rc: "set rnu\nset nowrap\n")
            defer { cleanup(app, directory) }
            try app.restoreWindows(reopeningRecent: false)
            let terminal = app.editors[0].terminal
            XCTAssertFalse(terminal.gutter.isHidden)
            XCTAssertTrue(terminal.textView.enclosingScrollView!.hasHorizontalScroller)
        }
    }

    func test_display_options_still_apply_with_vim_keybindings_off() async {
        await MainActor.run {
            let (terminal, window) = editorWindow("a\nb")
            defer { window.contentView = nil }
            terminal.textView.vimEnabled = false
            set("number cursorline", in: terminal)
            XCTAssertEqual(terminal.gutter.rows.map(\.text), ["1", "2"])
            XCTAssertGreaterThan(
                litPixels(terminal.textView, farRight(of: 0, in: terminal.textView)), 0
            )
        }
    }

    // MARK: Helpers

    @MainActor private func editorWindow(_ text: String) -> (TerminalView, NSWindow) {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let window = NSWindow(
            contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.textView)
        terminal.textView.string = text
        terminal.textView.setSelectedRange(NSRange(location: 0, length: 0))
        terminal.layoutSubtreeIfNeeded()
        return (terminal, window)
    }

    @MainActor private func set(_ arguments: String, in terminal: TerminalView) {
        _ = try? terminal.textView.store.session.options.set(arguments)
        terminal.applyDisplayOptions()
        terminal.layoutSubtreeIfNeeded()
    }

    @MainActor private func fragmentCount(_ view: NSTextView) -> Int {
        guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        var count = 0
        layout.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)
        ) { _, _, _, _, _ in count += 1 }
        return count
    }

    /// The x of the glyph for the character at `index`, within the text container.
    @MainActor private func columnX(of index: Int, in view: NSTextView) -> CGFloat {
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let glyph = layout.glyphIndexForCharacter(at: index)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
            + layout.location(forGlyphAt: glyph).x
    }

    /// The y, in the gutter's space, of the first screen row of logical line `line`.
    @MainActor private func fragmentTop(
        ofLine line: Int, in view: NSTextView, gutter: NSView
    ) -> CGFloat {
        let text = view.string as NSString
        var start = 0
        for _ in 0..<line {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
        }
        let layout = view.layoutManager!
        let glyph = layout.glyphIndexForCharacter(at: start)
        let top = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        return gutter.convert(NSPoint(x: 0, y: top + view.textContainerOrigin.y), from: view).y
    }

    /// The view-space box of the character at `index`.
    @MainActor private func cellRect(_ index: Int, in view: NSTextView) -> NSRect {
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let range = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                      actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: range, in: view.textContainer!)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    /// The box just after the last character of logical line `line`, where `$` is drawn.
    @MainActor private func endRect(of line: Int, in view: NSTextView) -> NSRect {
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let text = view.string as NSString
        var start = 0
        for _ in 0..<line {
            start = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
        }
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                          for: NSRange(location: start, length: 0))
        let glyph = layout.glyphIndexForCharacter(at: max(contentsEnd - 1, 0))
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSRect(x: used.maxX + view.textContainerOrigin.x, y: used.minY
            + view.textContainerOrigin.y, width: cell, height: used.height)
    }

    @MainActor private func farRight(of line: Int, in view: NSTextView) -> NSRect {
        let row = cellRect(
            (view.string as NSString).range(of: ["a", "b", "c"][line]).location, in: view
        )
        return NSRect(x: view.bounds.maxX - 40, y: row.minY, width: 30, height: row.height)
    }

    /// How many pixels in `rect` of `view` are visibly painted; the views draw no background.
    @MainActor private func litPixels(_ view: NSView, _ rect: NSRect) -> Int {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        var count = 0
        let minX = max(Int(rect.minX * scale), 0)
        let maxX = min(Int(rect.maxX * scale), image.pixelsWide)
        let minY = max(Int(rect.minY * scale), 0)
        let maxY = min(Int(rect.maxY * scale), image.pixelsHigh)
        for y in minY..<max(maxY, minY) {
            for x in minX..<max(maxX, minX) {
                if let color = image.colorAt(x: x, y: y), color.alphaComponent > 0.03 { count += 1 }
            }
        }
        return count
    }

    @MainActor private func workspace(rc: String? = nil) throws -> (AppDelegate, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rcURL: URL?
        if let rc {
            rcURL = directory.appendingPathComponent("amberrc")
            try rc.write(to: rcURL!, atomically: true, encoding: .utf8)
        }
        let app = AppDelegate(
            recoveryURL: directory.appendingPathComponent("Recovery.json"), rcURL: rcURL
        )
        return (app, directory)
    }

    @MainActor private func cleanup(_ app: AppDelegate, _ directory: URL) {
        for editor in app.editors { editor.window.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}
