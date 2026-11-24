import XCTest
@testable import NotepadCore

/// Expected cursors and top lines were taken from Vim 9.1 in a 10-line window over
/// `numberedLines(100)`, with the cursor starting at column 4.
final class VimScrollTests: XCTestCase {
    private struct Case {
        let scrolloff: Int
        let line: Int
        let top: Int
        let keys: String
        let after: (line: Int, column: Int, top: Int)
        let effects: [VimEffect]
    }

    private func top(_ line: Int) -> VimEffect { .scroll(.top(line: line)) }

    private func check(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            var session = VimSession()
            session.options.scrolloff = c.scrolloff
            let run = runVim(numberedLines(100, cursorLine: c.line, column: 4), c.keys,
                             session: session, lines: 10, top: c.top)
            let label = "so=\(c.scrolloff) line \(c.line) top \(c.top) keys \(c.keys)"
            XCTAssertEqual(run.rendered,
                           numberedLines(100, cursorLine: c.after.line, column: c.after.column),
                           label, file: file, line: line)
            XCTAssertEqual(run.top, c.after.top, label, file: file, line: line)
            XCTAssertEqual(run.effects, c.effects, label, file: file, line: line)
        }
    }

    func test_control_e_and_control_y_scroll_by_lines_and_keep_the_column() {
        check([
            Case(scrolloff: 0, line: 0, top: 0, keys: "<C-e>", after: (1, 4, 1), effects: [top(1)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "3<C-e>", after: (3, 4, 3),
                 effects: [top(3)]),
            Case(scrolloff: 0, line: 6, top: 0, keys: "<C-e>", after: (6, 4, 1), effects: [top(1)]),
            Case(scrolloff: 0, line: 95, top: 90, keys: "20<C-e>", after: (99, 4, 99),
                 effects: [top(99)]),
            Case(scrolloff: 0, line: 12, top: 5, keys: "<C-y>", after: (12, 4, 4),
                 effects: [top(4)]),
            Case(scrolloff: 0, line: 12, top: 5, keys: "3<C-y>", after: (11, 4, 2),
                 effects: [top(2)]),
            Case(scrolloff: 0, line: 14, top: 5, keys: "3<C-y>", after: (11, 4, 2),
                 effects: [top(2)]),
            Case(scrolloff: 0, line: 3, top: 0, keys: "<C-y>", after: (3, 4, 0), effects: []),
        ])
    }

    func test_control_e_and_control_y_keep_the_cursor_inside_scrolloff() {
        check([
            Case(scrolloff: 3, line: 0, top: 0, keys: "<C-e>", after: (4, 4, 1), effects: [top(1)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "3<C-e>", after: (6, 4, 3),
                 effects: [top(3)]),
            Case(scrolloff: 3, line: 6, top: 0, keys: "<C-e>", after: (6, 4, 1), effects: [top(1)]),
            Case(scrolloff: 3, line: 95, top: 90, keys: "20<C-e>", after: (99, 4, 99),
                 effects: [top(99)]),
            Case(scrolloff: 3, line: 10, top: 5, keys: "<C-y>", after: (10, 4, 4),
                 effects: [top(4)]),
            Case(scrolloff: 3, line: 10, top: 5, keys: "3<C-y>", after: (8, 4, 2),
                 effects: [top(2)]),
        ])
    }

    func test_control_d_and_control_u_scroll_half_a_page_and_move_the_cursor_with_it() {
        check([
            Case(scrolloff: 0, line: 0, top: 0, keys: "<C-d>", after: (5, 0, 5), effects: [top(5)]),
            Case(scrolloff: 0, line: 86, top: 86, keys: "<C-d>", after: (91, 0, 90),
                 effects: [top(90)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "<C-u>", after: (45, 0, 40),
                 effects: [top(40)]),
            Case(scrolloff: 0, line: 4, top: 0, keys: "<C-u>", after: (0, 2, 0), effects: []),
            Case(scrolloff: 3, line: 0, top: 0, keys: "<C-d>", after: (8, 2, 5), effects: [top(5)]),
            Case(scrolloff: 3, line: 89, top: 86, keys: "<C-d>", after: (94, 2, 90),
                 effects: [top(90)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "<C-u>", after: (45, 0, 40),
                 effects: [top(40)]),
            Case(scrolloff: 3, line: 4, top: 0, keys: "<C-u>", after: (0, 2, 0), effects: []),
        ])
    }

    func test_a_count_on_control_d_sets_the_scroll_amount_for_later_ones() {
        check([
            Case(scrolloff: 0, line: 0, top: 0, keys: "3<C-d>", after: (3, 0, 3),
                 effects: [top(3)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "3<C-d><C-d>", after: (6, 2, 6),
                 effects: [top(3), top(6)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "2<C-u>", after: (48, 2, 43),
                 effects: [top(43)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "3<C-d>", after: (6, 2, 3),
                 effects: [top(3)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "3<C-d><C-d>", after: (9, 0, 6),
                 effects: [top(3), top(6)]),
        ])
    }

    func test_a_count_on_control_d_and_control_u_is_capped_at_the_window_height() {
        check([
            Case(scrolloff: 0, line: 0, top: 0, keys: "100<C-d>", after: (10, 2, 10),
                 effects: [top(10)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "100<C-d>gg<C-d>", after: (10, 2, 10),
                 effects: [top(10), top(10)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "100<C-d><C-u>", after: (0, 2, 0),
                 effects: [top(10), top(0)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "100<C-u>", after: (40, 2, 35),
                 effects: [top(35)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "100<C-d>", after: (13, 0, 10),
                 effects: [top(10)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "100<C-d>gg<C-d>", after: (13, 0, 10),
                 effects: [top(10), top(10)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "100<C-d><C-u>", after: (3, 0, 0),
                 effects: [top(10), top(0)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "100<C-u>", after: (40, 2, 35),
                 effects: [top(35)]),
        ])
    }

    func test_control_d_on_the_last_line_and_control_u_on_the_first_fail() {
        check([
            Case(scrolloff: 0, line: 99, top: 90, keys: "<C-d>", after: (99, 4, 90),
                 effects: [.failure]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "<C-u>", after: (0, 4, 0),
                 effects: [.failure]),
        ])
    }

    func test_control_f_and_control_b_scroll_by_pages_keeping_two_lines() {
        check([
            Case(scrolloff: 0, line: 0, top: 0, keys: "<C-f>", after: (8, 2, 8), effects: [top(8)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "2<C-f>", after: (16, 2, 16),
                 effects: [top(16)]),
            Case(scrolloff: 0, line: 86, top: 86, keys: "<C-f>", after: (94, 2, 94),
                 effects: [top(94)]),
            Case(scrolloff: 0, line: 95, top: 90, keys: "<C-f>", after: (99, 0, 99),
                 effects: [top(99)]),
            Case(scrolloff: 0, line: 0, top: 0, keys: "<PageDown>", after: (8, 2, 8),
                 effects: [top(8)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "<C-b>", after: (46, 2, 37),
                 effects: [top(37)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "2<C-b>", after: (38, 2, 29),
                 effects: [top(29)]),
            Case(scrolloff: 0, line: 6, top: 4, keys: "<C-b>", after: (9, 0, 0), effects: [top(0)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "<PageUp>", after: (46, 2, 37),
                 effects: [top(37)]),
        ])
    }

    func test_control_f_and_control_b_put_the_cursor_inside_scrolloff() {
        check([
            Case(scrolloff: 3, line: 0, top: 0, keys: "<C-f>", after: (11, 0, 8),
                 effects: [top(8)]),
            Case(scrolloff: 3, line: 0, top: 0, keys: "2<C-f>", after: (19, 0, 16),
                 effects: [top(16)]),
            Case(scrolloff: 3, line: 89, top: 86, keys: "<C-f>", after: (97, 0, 94),
                 effects: [top(94)]),
            Case(scrolloff: 3, line: 95, top: 90, keys: "<C-f>", after: (99, 0, 99),
                 effects: [top(99)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "<C-b>", after: (43, 0, 37),
                 effects: [top(37)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "2<C-b>", after: (35, 0, 29),
                 effects: [top(29)]),
            Case(scrolloff: 3, line: 8, top: 4, keys: "<C-b>", after: (6, 2, 0), effects: [top(0)]),
        ])
    }

    func test_control_f_at_the_end_and_control_b_at_the_start_fail() {
        check([
            Case(scrolloff: 0, line: 99, top: 99, keys: "<C-f>", after: (99, 4, 99),
                 effects: [.failure]),
            Case(scrolloff: 0, line: 3, top: 0, keys: "<C-b>", after: (3, 4, 0),
                 effects: [.failure]),
        ])
    }

    func test_z_commands_place_the_cursor_line_and_keep_the_column() {
        check([
            Case(scrolloff: 0, line: 50, top: 45, keys: "zz", after: (50, 4, 46),
                 effects: [.scroll(.center(line: 50))]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "zt", after: (50, 4, 50),
                 effects: [top(50)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "zb", after: (50, 4, 41),
                 effects: [.scroll(.bottom(line: 50))]),
            Case(scrolloff: 0, line: 2, top: 0, keys: "zz", after: (2, 4, 0),
                 effects: [.scroll(.center(line: 2))]),
            Case(scrolloff: 0, line: 99, top: 90, keys: "zz", after: (99, 4, 95),
                 effects: [.scroll(.center(line: 99))]),
            Case(scrolloff: 0, line: 99, top: 90, keys: "zt", after: (99, 4, 99),
                 effects: [top(99)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "zz", after: (50, 4, 46),
                 effects: [.scroll(.center(line: 50))]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "zt", after: (50, 4, 47),
                 effects: [top(47)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "zb", after: (50, 4, 44),
                 effects: [.scroll(.bottom(line: 53))]),
            Case(scrolloff: 3, line: 99, top: 90, keys: "zt", after: (99, 4, 96),
                 effects: [top(96)]),
            Case(scrolloff: 3, line: 99, top: 90, keys: "zb", after: (99, 4, 90),
                 effects: [.scroll(.bottom(line: 99))]),
        ])
    }

    func test_z_enter_dot_and_minus_also_go_to_the_first_non_blank() {
        check([
            Case(scrolloff: 0, line: 50, top: 45, keys: "z<CR>", after: (50, 2, 50),
                 effects: [top(50)]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "z.", after: (50, 2, 46),
                 effects: [.scroll(.center(line: 50))]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "z-", after: (50, 2, 41),
                 effects: [.scroll(.bottom(line: 50))]),
            Case(scrolloff: 0, line: 50, top: 45, keys: "10z<CR>", after: (9, 0, 9),
                 effects: [top(9)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "z<CR>", after: (50, 2, 47),
                 effects: [top(47)]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "z.", after: (50, 2, 46),
                 effects: [.scroll(.center(line: 50))]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "10z.", after: (9, 0, 5),
                 effects: [.scroll(.center(line: 9))]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "z-", after: (50, 2, 44),
                 effects: [.scroll(.bottom(line: 53))]),
            Case(scrolloff: 3, line: 50, top: 45, keys: "10z<CR>", after: (9, 0, 6),
                 effects: [top(6)]),
        ])
    }
}
