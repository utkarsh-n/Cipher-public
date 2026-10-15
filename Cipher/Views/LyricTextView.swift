import SwiftUI
import UIKit

/// What the editor knows about where the writer is, recomputed on every edit or caret move.
struct CaretContext: Equatable {
    /// The selection, or the word the caret is touching.
    var focus: String?
    /// The last word of the nearest non-blank line above, within the same stanza.
    var previousLineEnd: String?
    /// True when nothing but whitespace follows the caret on its line.
    var atLineEnd = true
    var line = ""
    /// The caret's line without its newline.
    var lineRange = NSRange(location: 0, length: 0)
    var previousLine: String?
    var previousLineRange: NSRange?

    /// The last few words of the line above: what a multisyllabic rhyme has to answer.
    var previousLineTail: String? {
        guard let previousLine else { return nil }
        let source = previousLine as NSString
        let words = Tokenizer.pattern.matches(in: previousLine, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        return words.suffix(3).joined(separator: " ")
    }
}

/// Lets SwiftUI views push edits into the UITextView without fighting its selection.
@MainActor
final class LyricController {
    fileprivate weak var textView: UITextView?
    /// Opens the sphere on the caret's line or word; the keyboard strip's sphere key calls it.
    var onOrbit: (() -> Void)?

    /// Puts a chain separator at the caret, spaced the way the writer spaces them: "a : b".
    func insertSeparator(_ separator: String) {
        guard let textView else { return }
        // A word still being composed (a transliteration keyboard's marked text) is committed first.
        if textView.markedTextRange != nil { textView.unmarkText() }
        guard let selection = textView.selectedTextRange else { return }
        let text = textView.text as NSString
        let location = textView.selectedRange.location
        var leading = " "
        if location == 0 {
            leading = ""
        } else if let scalar = UnicodeScalar(text.character(at: location - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            leading = ""
        }
        textView.replace(selection, withText: leading + separator + " ")
        textView.delegate?.textViewDidChange?(textView)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// Inserts a word at the caret, adding a leading space when it would otherwise butt up
    /// against the previous word.
    func insert(word: String) {
        guard let textView, let selection = textView.selectedTextRange else { return }
        let text = textView.text as NSString
        let location = textView.selectedRange.location
        var needsSpace = false
        if location > 0, let scalar = UnicodeScalar(text.character(at: location - 1)) {
            needsSpace = !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        textView.replace(selection, withText: (needsSpace ? " " : "") + word)
        textView.delegate?.textViewDidChange?(textView)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// Replaces a whole line (range excludes the newline).
    func replace(_ range: NSRange, with line: String) {
        guard let textView, NSMaxRange(range) <= (textView.text as NSString).length,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: line)
        textView.delegate?.textViewDidChange?(textView)
    }

    /// Adds a new line directly below the given line.
    func insertLine(_ line: String, after range: NSRange) {
        guard let textView, NSMaxRange(range) <= (textView.text as NSString).length,
              let position = textView.position(from: textView.beginningOfDocument, offset: NSMaxRange(range)),
              let textRange = textView.textRange(from: position, to: position) else { return }
        textView.replace(textRange, withText: (range.length == 0 ? "" : "\n") + line)
        textView.delegate?.textViewDidChange?(textView)
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }
}

/// The lyric editor: a UITextView with rhyme highlights painted behind the words and a gutter
/// showing each bar's rhyme letter and syllable count.
struct LyricTextView: UIViewRepresentable {
    @Binding var text: String
    var analysis: VerseAnalysis
    var showHighlights: Bool
    /// For a song written out from a recording: when each bar starts, one entry per line.
    /// Kept in step with the lines as they are edited.
    @Binding var times: [Double]
    /// The line being sung right now, while the recording plays.
    var currentLine: Int? = nil
    /// Room under the text for whatever sits over the editor (the tray, or the sphere).
    var bottomInset: CGFloat = 120
    let controller: LyricController
    var onCaret: (CaretContext) -> Void
    var onFocus: (Bool) -> Void

    /// Wider when there are time codes to show beside the rhyme letters.
    static func gutterWidth(timed: Bool) -> CGFloat { timed ? 86 : 48 }

    var gutterWidth: CGFloat { Self.gutterWidth(timed: !times.isEmpty) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> GutteredTextView {
        let view = GutteredTextView.make()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = Coordinator.font
        view.typingAttributes = Coordinator.baseAttributes
        view.gutterWidth = gutterWidth
        view.textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth, bottom: bottomInset, right: 14)
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        // Slang and dropped g's are the point; autocorrect would fight every bar.
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.autocapitalizationType = .sentences
        view.text = text
        // Chains are written with colons, which the iPhone keyboard keeps two layers down.
        let strip = ChainKeyStrip()
        strip.onSeparator = { [weak controller] in controller?.insertSeparator($0) }
        strip.onOrbit = { [weak controller] in controller?.onOrbit?() }
        strip.onDone = { [weak view] in view?.resignFirstResponder() }
        view.inputAccessoryView = strip
        context.coordinator.textView = view
        context.coordinator.applyBaseAttributes()
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutGutter() }
        controller.textView = view
        context.coordinator.restyle()
        return view
    }

    func updateUIView(_ view: GutteredTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            context.coordinator.applyBaseAttributes()
        }
        if view.gutterWidth != gutterWidth {
            view.gutterWidth = gutterWidth
            view.textContainerInset.left = gutterWidth
            view.setNeedsLayout()
        }
        if view.textContainerInset.bottom != bottomInset {
            view.textContainerInset.bottom = bottomInset
            view.scrollRangeToVisible(view.selectedRange)
        }
        context.coordinator.restyle()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LyricTextView
        weak var textView: GutteredTextView?
        private var applied: (analysis: VerseAnalysis, highlights: Bool, current: Int?)?

        static let font = UIFont.preferredFont(forTextStyle: .body)
        static let baseAttributes: [NSAttributedString.Key: Any] = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7
            return [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        }()

        init(_ parent: LyricTextView) { self.parent = parent }

        /// Bar times stay with their bars: a line added or removed inside the text shifts the
        /// entries after it, so the gutter never shows a bar the time of the one above.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !parent.times.isEmpty, NSMaxRange(range) <= (textView.text as NSString).length else { return true }
            let whole = textView.text as NSString
            let line = whole.substring(to: range.location).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let removed = whole.substring(with: range).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            let added = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
            guard removed != added else { return true }
            var times = parent.times
            if added > removed {
                let stamp = line < times.count ? times[line] : times.last ?? 0
                times.insert(contentsOf: Array(repeating: stamp, count: added - removed), at: min(line + 1, times.count))
            } else {
                let start = min(line + 1, times.count)
                let end = min(start + (removed - added), times.count)
                times.removeSubrange(start..<end)
            }
            parent.times = times
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onCaret(caretContext(textView))
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = Self.baseAttributes
            parent.onCaret(caretContext(textView))
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocus(true) }

        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocus(false) }

        /// Setting `text` wholesale drops the paragraph style; put it back.
        func applyBaseAttributes() {
            guard let textView else { return }
            let storage = textView.textStorage
            storage.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: storage.length))
            textView.typingAttributes = Self.baseAttributes
            applied = nil
        }

        /// Repaints highlights and the gutter once the analysis has caught up with the text.
        /// While it trails behind a keystroke, the existing highlights simply ride along with
        /// their words.
        func restyle() {
            guard let textView, textView.markedTextRange == nil else { return }
            let storage = textView.textStorage
            let analysis = parent.analysis
            guard analysis.length == storage.length else { return }
            if let applied, applied.analysis == analysis, applied.highlights == parent.showHighlights, applied.current == parent.currentLine { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(Self.baseAttributes, range: whole)
            // The bar being sung gets a faint wash under its words; rhyme colours paint over it.
            if let current = parent.currentLine, let line = analysis.lines.first(where: { lineNumber(at: $0.range.location, in: storage.string) == current }),
               NSMaxRange(line.range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: UIColor(Theme.accent).withAlphaComponent(0.12), range: line.range)
            }
            if parent.showHighlights {
                for highlight in analysis.highlights where NSMaxRange(highlight.range) <= storage.length {
                    let color = Theme.highlighter(highlight.color)
                    storage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.3), range: highlight.range)
                    storage.addAttribute(.foregroundColor, value: UIColor.white, range: highlight.range)
                }
            }
            storage.endEditing()
            textView.typingAttributes = Self.baseAttributes
            applied = (analysis, parent.showHighlights, parent.currentLine)
            layoutGutter()
        }

        /// Which line of the text a character sits on, counting from zero.
        private func lineNumber(at location: Int, in text: String) -> Int {
            let utf16 = text.utf16
            let end = utf16.index(utf16.startIndex, offsetBy: min(location, utf16.count))
            return utf16[utf16.startIndex..<end].reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        }

        func layoutGutter() {
            guard let textView, parent.analysis.length == textView.textStorage.length else { return }
            let layout = textView.layoutManager
            let length = textView.textStorage.length
            var marks: [GutterView.Mark] = []
            let text = textView.textStorage.string
            for line in parent.analysis.lines where line.scheme != nil && line.range.location < length {
                let glyph = layout.glyphIndexForCharacter(at: line.range.location)
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let number = parent.times.isEmpty ? -1 : lineNumber(at: line.range.location, in: text)
                let time = number >= 0 && number < parent.times.count ? Playback.clock(parent.times[number]) : ""
                marks.append(GutterView.Mark(y: rect.minY + textView.textContainerInset.top, scheme: parent.showHighlights ? line.scheme ?? "" : "",
                                             syllables: line.syllables, time: time, current: number >= 0 && number == parent.currentLine))
            }
            textView.gutter.marks = marks
        }

        private func caretContext(_ textView: UITextView) -> CaretContext {
            let text = textView.text as NSString
            let selection = textView.selectedRange
            var context = CaretContext()
            guard selection.location != NSNotFound, selection.location <= text.length else { return context }

            let fullLine = text.lineRange(for: NSRange(location: selection.location, length: 0))
            let lineRange = Self.trimmingNewline(fullLine, in: text)
            context.lineRange = lineRange
            context.line = text.substring(with: lineRange)

            let lineEnd = NSMaxRange(lineRange)
            let caret = min(NSMaxRange(selection), lineEnd)
            context.atLineEnd = text.substring(with: NSRange(location: caret, length: lineEnd - caret))
                .trimmingCharacters(in: .whitespaces).isEmpty

            if selection.length > 0 {
                let selected = text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
                if !selected.isEmpty && selected.count <= 60 && !selected.contains("\n") { context.focus = selected }
            } else {
                var start = selection.location, end = selection.location
                while start > 0, Self.isWordCharacter(text.character(at: start - 1)) { start -= 1 }
                while end < text.length, Self.isWordCharacter(text.character(at: end)) { end += 1 }
                if end > start { context.focus = text.substring(with: NSRange(location: start, length: end - start)) }
            }

            // The line above, as long as it is part of the same stanza.
            if fullLine.location > 0 {
                let above = Self.trimmingNewline(text.lineRange(for: NSRange(location: fullLine.location - 1, length: 0)), in: text)
                let aboveText = text.substring(with: above)
                if let last = Self.lastWord(aboveText) {
                    context.previousLineEnd = last
                    context.previousLine = aboveText
                    context.previousLineRange = above
                }
            }
            return context
        }

        private static func trimmingNewline(_ range: NSRange, in text: NSString) -> NSRange {
            var length = range.length
            while length > 0, let scalar = UnicodeScalar(text.character(at: range.location + length - 1)),
                  CharacterSet.newlines.contains(scalar) {
                length -= 1
            }
            return NSRange(location: range.location, length: length)
        }

        /// Letters and the marks that ride on them: Devanagari and Gujarati vowel signs are marks.
        private static func isWordCharacter(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) || unit == 39 || unit == 0x2019
        }

        static func lastWord(_ line: String) -> String? {
            let source = line as NSString
            return Tokenizer.pattern.matches(in: line, range: NSRange(location: 0, length: source.length)).last.map { source.substring(with: $0.range) }
        }
    }
}

/// The keys a chain needs, over the keyboard: the separators and the sphere.
final class ChainKeyStrip: UIInputView {
    var onSeparator: ((String) -> Void)?
    var onOrbit: (() -> Void)?
    var onDone: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 50), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        for separator in [":", "::", "→"] {
            stack.addArrangedSubview(key(title: separator, symbol: nil, label: "Insert \(separator)") { [weak self] in self?.onSeparator?(separator) })
        }
        stack.addArrangedSubview(UIView())
        stack.addArrangedSubview(key(title: nil, symbol: "circle.hexagonpath", label: "Open the sphere") { [weak self] in self?.onOrbit?() })
        stack.addArrangedSubview(key(title: nil, symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") { [weak self] in self?.onDone?() })
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func key(title: String?, symbol: String?, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.title = title
        // The glass style draws symbols in the label colour; the strip's keys are all accent.
        if let symbol { configuration.image = UIImage(systemName: symbol)?.withTintColor(UIColor(Theme.accent), renderingMode: .alwaysOriginal) }
        configuration.baseForegroundColor = UIColor(Theme.accent)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .bold)
            return outgoing
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        button.accessibilityLabel = label
        return button
    }
}

extension ChainKeyStrip: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class GutteredTextView: UITextView {
    let gutter = GutterView()
    var gutterWidth: CGFloat = 48
    var onLayout: (() -> Void)?
    private var lastSize = CGSize.zero
    private var storage: NSTextStorage?

    /// Builds the view on an explicit TextKit 1 stack, so the gutter can ask the layout manager
    /// where each line sits. (`UITextView(usingTextLayoutManager:)` is an Objective-C factory
    /// that skips this subclass's stored-property initialization.)
    static func make() -> GutteredTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = GutteredTextView(frame: .zero, textContainer: container)
        view.storage = storage
        return view
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        gutter.backgroundColor = .clear
        // Redraw rather than stretch the old bitmap when the text grows.
        gutter.contentMode = .redraw
        gutter.isUserInteractionEnabled = false
        addSubview(gutter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = CGSize(width: bounds.width, height: max(contentSize.height, bounds.height))
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: size.height)
        // Scrolling calls this constantly; only re-measure when the text has reflowed.
        if size != lastSize {
            lastSize = size
            onLayout?()
        }
    }
}

/// Draws "A 10" beside each bar: its end-rhyme letter and syllable count, and for a bar
/// written out from a recording, when it is sung.
final class GutterView: UIView {
    struct Mark: Equatable {
        let y: CGFloat
        let scheme: String
        let syllables: Int
        var time = ""
        var current = false
    }

    var marks: [Mark] = [] {
        didSet { if marks != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        let letterFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let countFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        for mark in marks where mark.y + lineHeight >= rect.minY && mark.y <= rect.maxY {
            let baseline = mark.y + (lineHeight - letterFont.lineHeight) / 2 + 1
            if mark.current {
                UIColor(Theme.accent).setFill()
                UIBezierPath(roundedRect: CGRect(x: 3, y: mark.y + 2, width: 3, height: lineHeight - 4), cornerRadius: 1.5).fill()
            }
            if !mark.time.isEmpty {
                (mark.time as NSString).draw(at: CGPoint(x: 26, y: baseline + 1), withAttributes: [.font: timeFont, .foregroundColor: mark.current ? UIColor(Theme.accent) : UIColor.tertiaryLabel])
            }
            if !mark.scheme.isEmpty {
                let scalar = mark.scheme.unicodeScalars.first.map { Int($0.value) - 65 } ?? 0
                (mark.scheme as NSString).draw(at: CGPoint(x: 12, y: baseline), withAttributes: [.font: letterFont, .foregroundColor: Theme.highlighter(scalar)])
            }
            let count = "\(mark.syllables)" as NSString
            let width = count.size(withAttributes: [.font: countFont]).width
            count.draw(at: CGPoint(x: bounds.width - 8 - width, y: baseline), withAttributes: [.font: countFont, .foregroundColor: UIColor.tertiaryLabel])
        }
    }
}
