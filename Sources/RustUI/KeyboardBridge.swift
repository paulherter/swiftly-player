#if os(iOS)
import UIKit

/// A minimal UITextInput that carries what the soft keyboard types into the Rust text field: insertText, deleteBackward,
/// marked text (composition) and the return key. Rust owns the field's text, so this document only mirrors the marked run.
final class KeyboardBridge: UIView, UITextInput {
    weak var owner: RustView?
    private var marked = ""
    private var wantedNow = false

    override var canBecomeFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Called after every event and frame: shows or hides the keyboard when Rust gains or loses a text field.
    func update(wanted: Bool) {
        guard wanted != wantedNow, let owner else { return }
        wantedNow = wanted
        if wanted {
            if superview == nil { owner.addSubview(self) }
            _ = becomeFirstResponder()
        } else {
            marked = ""
            _ = resignFirstResponder()
        }
    }

    // Field traits: a search or login field, no autocorrect inside the Rust text.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .done

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { owner?.text(4, nil); return }
        // A commit replaces the composition in the Rust field.
        marked = ""
        owner?.text(0, text)
    }

    func deleteBackward() {
        if marked.isEmpty { owner?.text(3, nil) } else { marked = ""; owner?.text(2, nil) }
    }

    // MARK: UITextInput (document = the marked run only)

    final class Pos: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }
    final class Range: UITextRange {
        let a: Pos, b: Pos
        init(_ a: Pos, _ b: Pos) { self.a = a; self.b = b }
        override var start: UITextPosition { a }
        override var end: UITextPosition { b }
        override var isEmpty: Bool { a.offset == b.offset }
    }

    var selectedTextRange: UITextRange? {
        get { Range(Pos(marked.utf16.count), Pos(marked.utf16.count)) }
        set {}
    }
    var markedTextRange: UITextRange? { marked.isEmpty ? nil : Range(Pos(0), Pos(marked.utf16.count)) }
    var markedTextStyle: [NSAttributedString.Key: Any]?
    var beginningOfDocument: UITextPosition { Pos(0) }
    var endOfDocument: UITextPosition { Pos(marked.utf16.count) }
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    func text(in range: UITextRange) -> String? {
        guard let r = range as? Range else { return nil }
        let u = Array(marked.utf16)
        let lo = max(0, min(r.a.offset, r.b.offset)), hi = min(u.count, max(r.a.offset, r.b.offset))
        return String(utf16CodeUnits: Array(u[lo..<hi]), count: hi - lo)
    }

    func replace(_ range: UITextRange, withText text: String) { insertText(text) }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        marked = markedText ?? ""
        owner?.text(1, marked)
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        let t = marked
        marked = ""
        owner?.text(0, t)
    }

    func textRange(from a: UITextPosition, to b: UITextPosition) -> UITextRange? {
        guard let a = a as? Pos, let b = b as? Pos else { return nil }
        return Range(a, b)
    }
    func position(from p: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = p as? Pos else { return nil }
        return Pos(max(0, min(marked.utf16.count, p.offset + offset)))
    }
    func position(from p: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        position(from: p, offset: offset)
    }
    func compare(_ a: UITextPosition, to b: UITextPosition) -> ComparisonResult {
        guard let a = a as? Pos, let b = b as? Pos else { return .orderedSame }
        return a.offset < b.offset ? .orderedAscending : a.offset > b.offset ? .orderedDescending : .orderedSame
    }
    func offset(from a: UITextPosition, to b: UITextPosition) -> Int {
        guard let a = a as? Pos, let b = b as? Pos else { return 0 }
        return b.offset - a.offset
    }
    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { range.end }
    func characterRange(byExtending p: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { textRange(from: p, to: p) }
    func baseWritingDirection(for p: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ d: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { caret }
    func caretRect(for p: UITextPosition) -> CGRect { caret }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    /// Where the keyboard's candidate bar anchors: the bottom of the screen (Rust does not report the caret yet).
    private var caret: CGRect { CGRect(x: 0, y: (owner?.bounds.height ?? 0) - 40, width: 1, height: 20) }
}
#endif
