import SwiftUI
import UIKit

enum Theme {
    static let ink = Color(red: 0.047, green: 0.047, blue: 0.063)
    static let panel = Color.white.opacity(0.06)
    static let panelStroke = Color.white.opacity(0.09)
    static let accent = Color(red: 0.78, green: 0.96, blue: 0.2)

    /// Highlighter colours for rhyme groups; index with `color % palette.count`.
    static let highlighters: [UIColor] = [
        UIColor(red: 0.78, green: 0.96, blue: 0.20, alpha: 1), // lime
        UIColor(red: 0.22, green: 0.85, blue: 0.96, alpha: 1), // cyan
        UIColor(red: 1.00, green: 0.37, blue: 0.64, alpha: 1), // pink
        UIColor(red: 1.00, green: 0.62, blue: 0.11, alpha: 1), // orange
        UIColor(red: 0.65, green: 0.55, blue: 0.98, alpha: 1), // violet
        UIColor(red: 0.24, green: 0.94, blue: 0.69, alpha: 1), // mint
        UIColor(red: 1.00, green: 0.88, blue: 0.30, alpha: 1), // yellow
        UIColor(red: 1.00, green: 0.42, blue: 0.37, alpha: 1), // coral
    ]

    static func highlighter(_ index: Int) -> UIColor {
        highlighters[index % highlighters.count]
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, rows.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}

/// A tappable word, optionally with its other-script form beside it. Fainter chips are weaker matches.
struct WordChip: View {
    let title: String
    var aside: String?
    var strength: Double = 1
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint.opacity(0.55 + 0.45 * strength))
                if let aside {
                    Text(aside)
                        .font(.caption)
                        .foregroundStyle(tint.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tint.opacity(0.05 + 0.07 * strength), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.1 + 0.1 * strength)))
        }
        .buttonStyle(.plain)
    }
}

/// A chip for a word from the lexicon: shown in the writer's preferred script, with its
/// language, meaning and the usual actions on a long press.
struct HitChip: View {
    @Environment(AppModel.self) private var model
    let hit: RhymeHit
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        WordChip(title: hit.title(model.scriptDisplay), aside: hit.aside(model.scriptDisplay), strength: hit.score, tint: tint, action: action)
            .contextMenu {
                Section(hit.gloss.isEmpty ? hit.language.name : "\(hit.language.name) · \(hit.gloss)") {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = hit.word }
                    if !hit.roman.isEmpty {
                        Button("Copy in Roman letters", systemImage: "character.cursor.ibeam") { UIPasteboard.general.string = hit.roman }
                    }
                    Button("Open in Lab", systemImage: "waveform") { model.lookUp(hit) }
                    Button("Define", systemImage: "book") { model.defining = hit.word }
                }
            }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if let count {
                        Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.panelStroke))
    }
}

/// Chips that collapse to a first screenful with a "show all" toggle.
struct ChipCloud: View {
    let hits: [RhymeHit]
    var tint: Color = .white
    var initial = 24
    let onTap: (RhymeHit) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout {
                ForEach(expanded ? hits : Array(hits.prefix(initial))) { hit in
                    HitChip(hit: hit, tint: tint) { onTap(hit) }
                }
            }
            if hits.count > initial {
                Button(expanded ? "Show fewer" : "Show all \(hits.count)") { expanded.toggle() }
                    .font(.caption.weight(.semibold))
            }
        }
    }
}

/// Results split into one cloud per language, in the writer's order.
struct LanguageClouds: View {
    @Environment(AppModel.self) private var model
    let hits: [RhymeHit]
    var tint: Color = .white
    var initial = 14
    let onTap: (RhymeHit) -> Void

    var body: some View {
        let groups = model.languages.compactMap { language -> (language: Language, hits: [RhymeHit])? in
            let own = hits.filter { $0.language == language }
            return own.isEmpty ? nil : (language, own)
        }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.language) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if groups.count > 1 || group.language != .english {
                        LanguageLabel(language: group.language, count: group.hits.count)
                    }
                    ChipCloud(hits: group.hits, tint: tint, initial: groups.count > 1 ? initial : initial * 2, onTap: onTap)
                }
            }
        }
    }
}

struct LanguageLabel: View {
    let language: Language
    var count: Int?

    var body: some View {
        // The English name leads, so Hindi and Gujarati are never told apart by script alone.
        HStack(spacing: 6) {
            Text(language.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if language.nativeName != language.name {
                Text(language.nativeName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let count {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SuggestionCard<Actions: View>: View {
    let suggestion: Suggestion
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.text)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
            Text(suggestion.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) { actions }
                .font(.caption.weight(.semibold))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
    }
}

/// The system dictionary's entry for a word, in whichever dictionaries the phone has installed.
struct DictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
