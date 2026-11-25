import Foundation

/// The visible part of the text, supplied by the adapter for the commands that depend on
/// wrapping and the view: `gj`, `gk`, `H`, `M`, `L` and scrolling. Lines are logical lines
/// counted from 0.
public struct ScreenGeometry {
    /// The first fully visible line.
    public var firstVisibleLine: Int
    /// The last fully visible line.
    public var lastVisibleLine: Int
    /// The screen lines the view holds. The engine treats each line as one screen line when
    /// it estimates where the view ends after a scroll.
    public var linesPerPage: Int
    /// Moves an offset by a number of screen lines, down when positive, keeping its screen
    /// column where the target line allows.
    public var moveScreenLines: (Int, Int) -> Int

    public init(firstVisibleLine: Int, lastVisibleLine: Int, linesPerPage: Int,
                moveScreenLines: @escaping (Int, Int) -> Int) {
        self.firstVisibleLine = firstVisibleLine
        self.lastVisibleLine = lastVisibleLine
        self.linesPerPage = linesPerPage
        self.moveScreenLines = moveScreenLines
    }

    /// A view for tests: `lines` lines starting at `top`, where each line of `text` wraps
    /// after `wrapWidth` characters.
    public static func fake(lines: Int, top: Int = 0, text: NSString = "",
                            wrapWidth: Int = 80) -> ScreenGeometry {
        let buffer = VimBuffer(text)
        return ScreenGeometry(
            firstVisibleLine: top,
            lastVisibleLine: min(top + lines - 1, buffer.lineCount - 1),
            linesPerPage: lines,
            moveScreenLines: { offset, delta in
                fakeMove(offset, by: delta, in: buffer, wrapWidth: wrapWidth)
            })
    }

    private static func fakeMove(_ offset: Int, by delta: Int, in buffer: VimBuffer,
                                 wrapWidth: Int) -> Int {
        func graphemeStarts(_ line: Int) -> [Int] {
            let content = buffer.contentRange(at: line)
            var starts: [Int] = []
            var position = content.location
            while position < NSMaxRange(content), let next = buffer.nextGrapheme(after: position) {
                starts.append(position)
                position = next
            }
            return starts
        }
        var line = buffer.lineIndex(of: offset)
        var starts = graphemeStarts(line)
        let index = starts.firstIndex { $0 >= offset } ?? max(starts.count - 1, 0)
        let column = index % wrapWidth
        var row = index / wrapWidth
        for _ in 0..<abs(delta) {
            let rows = max((starts.count + wrapWidth - 1) / wrapWidth, 1)
            if delta > 0, row + 1 < rows {
                row += 1
            } else if delta > 0, line + 1 < buffer.lineCount {
                line += 1
                starts = graphemeStarts(line)
                row = 0
            } else if delta < 0, row > 0 {
                row -= 1
            } else if delta < 0, line > 0 {
                line -= 1
                starts = graphemeStarts(line)
                row = max((starts.count + wrapWidth - 1) / wrapWidth, 1) - 1
            }
        }
        guard !starts.isEmpty else { return buffer.lineRange(at: line).location }
        return starts[min(row * wrapWidth + column, starts.count - 1)]
    }
}

extension ScreenGeometry {
    /// The lines the cursor may rest on while the view shows its visible lines, keeping
    /// `scrolloff` lines from an edge unless the edge is an end of the text.
    public func cursorLines(lineCount: Int, scrolloff: Int) -> ClosedRange<Int> {
        Motions.cursorLines(top: firstVisibleLine, bottom: lastVisibleLine,
                            lineCount: lineCount, scrolloff: scrolloff)
    }
}

extension VimBuffer {
    /// Where Normal mode may rest the cursor: on a character, never on the line break.
    public func restingOffset(_ offset: Int) -> Int {
        Motions.normalPosition(offset, in: self)
    }
}
