import AppKit
import NotepadCore

/// Selection changes the adapter did not make are input, as Vim's `mouse=a` reads the mouse:
/// a click puts the cursor on a character, a drag starts Visual mode, a double-click selects
/// a word and a triple-click a line. Edits AppKit makes outside Vim, such as a paste, resync
/// the cursor the same way.
extension TerminalTextView {
    override func mouseDown(with event: NSEvent) {
        mouseClick = (characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)),
                      event.clickCount)
        super.mouseDown(with: event)
        mouseClick = nil
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        defer { cursorDidMove() }
        guard vimEnabled, !applyingState, !stillSelecting, !hasMarkedText() else { return }
        guard !isBatching else {
            batchMovedSelection = true
            return
        }
        adoptSelection(selectedRange())
    }

    private func adoptSelection(_ range: NSRange) {
        let buffer = currentBuffer()
        let outsideVim = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if range.length == 0 || outsideVim {
            adoptCursor(range.location, in: buffer)
        } else {
            adoptSelectedText(range, in: buffer)
        }
        syncMode()
    }

    func adoptCursor(_ location: Int, in buffer: VimBuffer) {
        if vim.mode.isVisual || vim.mode == .operatorPending { setModeKeepingCursor(.normal) }
        clearPendingCommand()
        vim.desiredColumn = nil
        let offset = min(location, buffer.length)
        if isInserting {
            vim.cursor = offset
            if !typingNatively { vim.insertSession?.start = offset }
            return
        }
        vim.cursor = buffer.restingOffset(offset)
        if vim.cursor != selectedRange().location || selectedRange().length != 0 {
            showSelection([NSRange(location: vim.cursor, length: 0)])
        }
    }

    private func setModeKeepingCursor(_ mode: VimMode) {
        vim.mode = mode
        vim.visualAnchor = nil
        vim.operatorKeys = []
    }

    private func adoptSelectedText(_ range: NSRange, in buffer: VimBuffer) {
        if isInserting { endUndoGroup() }
        let end = buffer.previousGrapheme(before: NSMaxRange(range)) ?? range.location
        let wholeLines = mouseClick?.count == 3
        let last = wholeLines ? buffer.restingOffset(end) : end
        let draggedBackwards = mouseClick.map { $0.offset > range.location && $0.count == 1 }
            ?? false
        clearPendingCommand()
        vim.insertSession = nil
        vim.changeInProgress = nil
        vim.mode = wholeLines ? .visualLine : .visual
        vim.visualAnchor = draggedBackwards ? last : range.location
        vim.cursor = draggedBackwards ? range.location : last
        vim.desiredColumn = nil
    }
}
