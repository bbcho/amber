import AppKit

@MainActor
final class TerminalTextView: NSTextView {
    enum Mode: String { case normal = "NORMAL", insert = "INSERT", visual = "VISUAL" }
    private(set) var mode: Mode = .normal
    var vimEnabled = true { didSet { setMode(vimEnabled ? .normal : .insert) } }
    var modeDidChange: (() -> Void)?
    var commandRequested: (() -> Void)?
    private var pending = ""
    private var count = ""
    private var register = ""
    private var linewiseRegister = false
    private var visualAnchor = 0
    private var visualCursor = 0

    func setMode(_ mode: Mode) {
        self.mode = mode
        pending = ""
        count = ""
        // AppKit caches caret visibility; reapply selection after changing the Vim mode.
        let selection = selectedRange()
        setSelectedRange(NSRange(
            location: selection.location, length: mode == .normal ? 0 : selection.length
        ))
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
        modeDidChange?()
    }

    override var shouldDrawInsertionPoint: Bool { !vimEnabled || mode == .insert }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard vimEnabled, mode == .normal, window?.firstResponder === self,
              let window else { return }
        var actual = NSRange()
        let rect = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        var caret = convert(window.convertFromScreen(rect), from: nil)
        caret.size.width = ceil(Phosphor.font.maximumAdvancement.width)
        Phosphor.amber.withAlphaComponent(0.65).setFill()
        caret.fill()
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        let control = event.modifierFlags.contains(.control)
        if vimEnabled, event.keyCode == 53 || key == "\u{1b}" || (control && key == "[") {
            setMode(.normal)
            return
        }
        if !vimEnabled || event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option) {
            super.keyDown(with: event)
            return
        }
        guard mode != .insert else { super.keyDown(with: event); return }
        if mode == .normal, key == ":", !control {
            pending = ""
            count = ""
            commandRequested?()
            return
        }
        if control {
            switch key {
            case "r": undoManager?.redo()
            case "d": scrollPageDown(nil)
            case "u": scrollPageUp(nil)
            default: break
            }
            return
        }
        if key.count == 1, key.first?.isNumber == true, key != "0" || !count.isEmpty {
            if count.count < 4 { count += key }
            return
        }
        let repetitions = min(Int(count) ?? 1, 999)
        if !pending.isEmpty {
            let first = pending
            pending = ""
            count = ""
            if first == "g", key == "g" { moveToBeginningOfDocument(nil) }
            if first == "d", key == "d" { deleteLines(repetitions) }
            if first == "y", key == "y" { yankLines(repetitions) }
            if first == "c", key == "c" {
                moveToBeginningOfParagraph(nil)
                operate("c", motion: "$", count: repetitions)
            }
            if isMotion(key) { operate(first, motion: key, count: repetitions) }
            return
        }
        if ["g", "d", "y", "c"].contains(key) {
            if mode == .visual, key != "g" {
                yankSelection()
                if key != "y" { insertText("", replacementRange: selectedRange()) }
                setMode(key == "c" ? .insert : .normal)
            } else { pending = key }
            return
        }
        count = ""
        if isMotion(key) {
            move(key, count: repetitions)
            return
        }
        switch key {
        case "i": setMode(.insert)
        case "a": moveRight(nil); setMode(.insert)
        case "I": moveToBeginningOfLine(nil); setMode(.insert)
        case "A": moveToEndOfLine(nil); setMode(.insert)
        case "o":
            moveToEndOfParagraph(nil)
            insertText("\n", replacementRange: selectedRange())
            setMode(.insert)
        case "O":
            moveToBeginningOfParagraph(nil)
            let start = selectedRange().location
            insertText("\n", replacementRange: selectedRange())
            setSelectedRange(NSRange(location: start, length: 0))
            setMode(.insert)
        case "x":
            if mode == .visual {
                yankSelection()
                insertText("", replacementRange: selectedRange())
                setMode(.normal)
            } else {
                for _ in 0..<repetitions { deleteCharacter() }
            }
        case "D":
            let start = selectedRange().location
            moveToEndOfParagraph(nil)
            let range = NSRange(location: start, length: selectedRange().location - start)
            register = (string as NSString).substring(with: range)
            linewiseRegister = false
            insertText("", replacementRange: range)
        case "p", "P": pasteRegister(after: key == "p", count: repetitions)
        case "u": undoManager?.undo()
        case "v":
            if mode == .visual { setMode(.normal) } else {
                visualAnchor = selectedRange().location
                visualCursor = visualAnchor
                setMode(.visual)
                selectVisualRange()
            }
        case "/": find(.showFindInterface)
        case "n": find(.nextMatch)
        case "N": find(.previousMatch)
        default:
            if [123, 124, 125, 126].contains(event.keyCode) { super.keyDown(with: event) }
        }
        needsDisplay = true
    }

    private func operate(_ operation: String, motion: String, count: Int) {
        guard ["d", "y", "c"].contains(operation) else { return }
        let start = selectedRange().location
        let actualMotion = operation == "c" && motion == "w" ? "e" : motion
        if operation == "c", motion == "w" {
            moveWord("e", advancing: false)
            for _ in 1..<count { moveWord("e") }
        } else {
            move(actualMotion, count: count)
        }
        var end = selectedRange().location
        let text = string as NSString
        if actualMotion == "e", end < text.length {
            end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: end))
        }
        let range = NSRange(location: min(start, end), length: abs(end - start))
        register = text.substring(with: range)
        linewiseRegister = false
        if operation == "y" {
            setSelectedRange(NSRange(location: start, length: 0))
        } else {
            insertText("", replacementRange: range)
            if operation == "c" { setMode(.insert) }
        }
    }

    private func isMotion(_ key: String) -> Bool {
        ["h", "j", "k", "l", "w", "b", "e", "0", "^", "$", "G"].contains(key)
    }

    private func move(_ key: String, count: Int) {
        if mode == .visual { setSelectedRange(NSRange(location: visualCursor, length: 0)) }
        for _ in 0..<count {
            switch key {
            case "h": moveLeft(nil)
            case "l": moveRight(nil)
            case "j": moveDown(nil)
            case "k": moveUp(nil)
            case "w", "b", "e": moveWord(key)
            case "0", "^": moveToBeginningOfParagraph(nil)
            case "$": moveToEndOfParagraph(nil)
            case "G": moveToEndOfDocument(nil)
            default: break
            }
        }
        if mode == .visual {
            visualCursor = selectedRange().location
            selectVisualRange()
        }
        scrollRangeToVisible(selectedRange())
        needsDisplay = true
    }

    private func moveWord(_ key: String, advancing: Bool = true) {
        let characters = Array(string)
        let prefix = (string as NSString).substring(to: selectedRange().location)
        var index = prefix.count
        func kind(_ character: Character) -> Int {
            if character.isWhitespace { return 0 }
            return character.isLetter || character.isNumber || character == "_" ? 1 : 2
        }
        if key == "b" {
            guard index > 0 else { return }
            index -= 1
            while index > 0, kind(characters[index]) == 0 { index -= 1 }
            let group = kind(characters[index])
            while index > 0, kind(characters[index - 1]) == group { index -= 1 }
        } else if key == "e", index < characters.count {
            if advancing { index = min(index + 1, characters.count - 1) }
            while index < characters.count - 1, kind(characters[index]) == 0 { index += 1 }
            let group = kind(characters[index])
            while index < characters.count - 1, kind(characters[index + 1]) == group { index += 1 }
        } else if index < characters.count {
            let group = kind(characters[index])
            while index < characters.count, kind(characters[index]) == group { index += 1 }
            while index < characters.count, kind(characters[index]) == 0 { index += 1 }
        }
        let offset = String(characters.prefix(index)).utf16.count
        setSelectedRange(NSRange(location: offset, length: 0))
    }

    private func lineRange(_ count: Int) -> NSRange {
        let text = string as NSString
        var range = text.lineRange(for: selectedRange())
        for _ in 1..<count where NSMaxRange(range) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            range.length = NSMaxRange(next) - range.location
        }
        return range
    }

    private func yankLines(_ count: Int) {
        register = (string as NSString).substring(with: lineRange(count))
        linewiseRegister = true
    }

    private func deleteLines(_ count: Int) {
        let range = lineRange(count)
        yankLines(count)
        insertText("", replacementRange: range)
    }

    private func deleteCharacter() {
        let text = string as NSString
        let offset = selectedRange().location
        guard offset < text.length else { return }
        let range = text.rangeOfComposedCharacterSequence(at: offset)
        register = text.substring(with: range)
        linewiseRegister = false
        insertText("", replacementRange: range)
    }

    private func yankSelection() {
        register = (string as NSString).substring(with: selectedRange())
        linewiseRegister = false
    }

    private func pasteRegister(after: Bool, count: Int) {
        guard !register.isEmpty else { return }
        let text = string as NSString
        var offset = selectedRange().location
        var value = String(repeating: register, count: count)
        if linewiseRegister {
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            offset = after ? NSMaxRange(line) : line.location
            if after, offset == text.length, !string.isEmpty, !string.hasSuffix("\n") {
                value = "\n" + value
            }
            if !value.hasSuffix("\n") { value += "\n" }
        } else if after, offset < text.length {
            offset = NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
        }
        insertText(value, replacementRange: NSRange(location: offset, length: 0))
        setSelectedRange(NSRange(location: offset, length: 0))
    }

    private func selectVisualRange() {
        let text = string as NSString
        let start = min(visualAnchor, visualCursor)
        let end = max(visualAnchor, visualCursor)
        let length = end < text.length ? text.rangeOfComposedCharacterSequence(at: end).length : 0
        setSelectedRange(NSRange(location: start, length: end - start + length))
    }

    private func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performFindPanelAction(item)
    }
}
