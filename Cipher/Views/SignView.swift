import CoreText
import SwiftUI

/// The Sutton SignWriting fonts, read as outlines. A sign is a handful of symbols placed on a
/// plane, so each symbol is drawn as a glyph path at its own coordinates rather than set as text.
@MainActor
final class SignGlyphs {
    static let shared = SignGlyphs()

    struct Symbol {
        let line: CGPath
        let fill: CGPath?
        let origin: CGPoint
        let size: CGSize
    }

    struct Sign {
        let symbols: [Symbol]
        let size: CGSize
    }

    /// The fonts are designed so that at 30 points one font unit is one SignWriting coordinate.
    private let line = SignGlyphs.font("SuttonSignWritingLine")
    private let fill = SignGlyphs.font("SuttonSignWritingFill")
    private var cache: [String: Sign] = [:]
    private static let symbolPattern = try! NSRegularExpression(pattern: "S([123][0-9a-f]{2})([0-5])([0-9a-f])(\\d{3})x(\\d{3})")

    private static func font(_ name: String) -> CTFont? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf"),
              let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, 30, nil)
    }

    private func path(_ font: CTFont?, _ code: UInt32) -> (path: CGPath, bounds: CGRect)? {
        guard let font, let scalar = UnicodeScalar(code) else { return nil }
        let units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return nil }
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, [glyphs[0]], &bounds, 1)
        return (path, bounds)
    }

    /// Parses Formal SignWriting ("M518x529S14c20481x471S27106503x489") into positioned outlines.
    func sign(_ fsw: String) -> Sign? {
        if let cached = cache[fsw] { return cached }
        let source = fsw as NSString
        var placed: [(line: CGPath, fill: CGPath?, x: CGFloat, y: CGFloat, size: CGSize)] = []
        for match in Self.symbolPattern.matches(in: fsw, range: NSRange(location: 0, length: source.length)) {
            func hex(_ group: Int) -> UInt32 { UInt32(source.substring(with: match.range(at: group)), radix: 16) ?? 0 }
            func number(_ group: Int) -> CGFloat { CGFloat(Int(source.substring(with: match.range(at: group))) ?? 500) }
            // Every base symbol has 6 fills x 16 rotations; the two fonts lay them out in Unicode's private planes.
            let id = 1 + (hex(1) - 0x100) * 96 + hex(2) * 16 + hex(3)
            guard let outline = path(line, 0xF0000 + id) else { continue }
            let size = CGSize(width: outline.bounds.width, height: outline.bounds.height)
            placed.append((outline.path, path(fill, 0x100000 + id)?.path, number(4), number(5), size))
        }
        guard !placed.isEmpty else { return nil }
        let minX = placed.map(\.x).min()!, minY = placed.map(\.y).min()!
        let maxX = placed.map { $0.x + $0.size.width }.max()!, maxY = placed.map { $0.y + $0.size.height }.max()!
        let sign = Sign(
            symbols: placed.map { Symbol(line: $0.line, fill: $0.fill, origin: CGPoint(x: $0.x - minX, y: $0.y - minY), size: $0.size) },
            size: CGSize(width: maxX - minX, height: maxY - minY)
        )
        cache[fsw] = sign
        return sign
    }
}

/// One sign in Sutton SignWriting, scaled to fit a given height.
struct SignView: View {
    let fsw: String
    var height: CGFloat = 56
    var color: Color = .white
    /// What sits behind the sign: hands are filled with it so overlapping symbols stay legible.
    var background: Color = Theme.ink

    var body: some View {
        if let sign = SignGlyphs.shared.sign(fsw) {
            // Never enlarge past the size the symbols were drawn for, and keep small signs small.
            let scale = min(1.1, height / max(sign.size.height, 1))
            Canvas { context, _ in
                for symbol in sign.symbols {
                    // Glyphs hang below their origin in y-up font space; flip them into the canvas.
                    var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: symbol.origin.x * scale, ty: symbol.origin.y * scale)
                    if let fill = symbol.fill, let moved = fill.copy(using: &transform) {
                        context.fill(Path(moved), with: .color(background))
                    }
                    if let moved = symbol.line.copy(using: &transform) {
                        context.fill(Path(moved), with: .color(color))
                    }
                }
            }
            .frame(width: sign.size.width * scale, height: sign.size.height * scale)
            .frame(height: height)
        }
    }
}

/// A bar as ASL: each signed word as its sign, each unsigned one spelled out on the hand.
struct SignStrip: View {
    let tokens: [SignToken]
    var height: CGFloat = 56
    var background: Color = Theme.ink

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(tokens) { token in
                    VStack(spacing: 4) {
                        if token.fingerspelled {
                            HStack(alignment: .center, spacing: 3) {
                                ForEach(Array(token.signs.enumerated()), id: \.offset) { _, letter in
                                    SignView(fsw: letter, height: height * 0.5, color: .white.opacity(0.75), background: background)
                                }
                            }
                            .frame(height: height)
                        } else if let sign = token.signs.first {
                            SignView(fsw: sign, height: height, color: Theme.accent, background: background)
                        }
                        Text(token.sense.isEmpty ? token.word : "\(token.word) · \(token.sense)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
