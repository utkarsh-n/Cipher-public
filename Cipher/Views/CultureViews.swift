import SwiftUI

extension Culture {
    /// Matches the colour each culture's language has in the editor tray.
    var tint: Color {
        switch self {
        case .us: .white
        case .india: Color(Theme.highlighter(3))
        case .spanish: Color(Theme.highlighter(7))
        case .french: Color(Theme.highlighter(1))
        case .world: Color(white: 0.7)
        }
    }
}

/// A work as a chip: what kind of thing it is, its title and its year.
struct WorkChip: View {
    let work: Work
    var strength: Double = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: work.kind.symbol)
                    .font(.caption2)
                    .foregroundStyle(work.culture.tint.opacity(0.6))
                // A chip never outgrows the screen: a long title is cut short, the sheet has it in full.
                Text(work.title.count > 30 ? work.title.prefix(29).trimmingCharacters(in: .whitespaces) + "…" : work.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(work.culture.tint.opacity(0.6 + 0.4 * strength))
                    .lineLimit(1)
                if let year = work.yearLabel {
                    Text(year)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(work.culture.tint.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(work.culture.tint.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(work.culture.tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// Works split by culture, in the writer's order.
struct WorkClouds: View {
    @Environment(AppModel.self) private var model
    let hits: [CultureHit]
    let onTap: (Work) -> Void

    var body: some View {
        let top = hits.first?.score ?? 1
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Culture.order(for: model.languages)) { culture in
                let own = hits.filter { $0.work.culture == culture }
                if !own.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(culture.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        FlowLayout {
                            ForEach(own.prefix(6)) { hit in
                                WorkChip(work: hit.work, strength: min(1, hit.score / max(top, 0.01))) { onTap(hit.work) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// When a word's works were made: one bar per decade.
struct DecadeBars: View {
    let decades: [(decade: Int, share: Double)]

    var body: some View {
        let peak = decades.map(\.share).max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(decades, id: \.decade) { entry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.35 + 0.65 * entry.share / peak))
                        .frame(height: max(3, 34 * entry.share / peak))
                        .frame(maxWidth: 14)
                }
            }
            .frame(height: 36, alignment: .bottom)
            if let first = decades.first, let last = decades.last {
                HStack {
                    Text("\(String(first.decade))s")
                    Spacer()
                    if let top = decades.max(by: { $0.share < $1.share }) { Text("most in the \(String(top.decade))s") }
                    Spacer()
                    Text("\(String(last.decade))s")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// What the culture index holds for the word being looked up.
struct CultureSection: View {
    let view: CultureView
    let onWork: (Work) -> Void
    var onTheme: (String) -> Void = { _ in }

    var body: some View {
        if !view.named.isEmpty || !view.about.isEmpty || !view.feeling.isEmpty || !view.neighbours.isEmpty {
            SectionCard(title: "In culture", subtitle: "Films, shows, sport and writing this word runs through") {
                if view.decades.count > 2 {
                    DecadeBars(decades: view.decades)
                }
                if !view.neighbours.isEmpty {
                    // What the corpus itself pairs this idea with, in every culture at once.
                    Text("Runs with").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    FlowLayout {
                        ForEach(view.neighbours, id: \.theme) { neighbour in
                            WordChip(title: neighbour.theme, strength: neighbour.weight, tint: Theme.accent) { onTheme(neighbour.theme) }
                        }
                    }
                }
                if !view.named.isEmpty {
                    Text("Named for it").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    WorkClouds(hits: view.named, onTap: onWork)
                }
                if !view.about.isEmpty {
                    Text("About it").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 4)
                    WorkClouds(hits: view.about, onTap: onWork)
                }
                if !view.feeling.isEmpty {
                    Text("Feels like it").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).padding(.top, 4)
                    WorkClouds(hits: view.feeling, onTap: onWork)
                }
            }
        }
        if !view.lines.isEmpty {
            SectionCard(title: "As written", subtitle: "The word in use, from writing now in the public domain") {
                ForEach(view.lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.text)
                            .font(.callout)
                            .textSelection(.enabled)
                        Text([line.author, line.title, line.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if line.id != view.lines.last?.id { Divider().overlay(Color.white.opacity(0.06)) }
                }
            }
        }
    }
}

/// One work in full: what it is, what it is about, what it stands for, and its relatives in
/// other cultures.
struct WorkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var work: Work
    @State private var detail: WorkDetail?
    /// Themes shared with each relative from another culture: what travelled across.
    @State private var carried: [Int: [String]] = [:]
    /// The works opened on the way here, so relatives can be explored and backed out of.
    @State private var trail: [Work] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let detail {
                        if !detail.meaning.isEmpty {
                            labelled("Stands for") { Text(detail.meaning).font(.body.italic()) }
                        }
                        if !detail.themes.isEmpty {
                            labelled("Themes") {
                                FlowLayout {
                                    ForEach(detail.themes.prefix(10), id: \.self) { theme in
                                        WordChip(title: theme.phrase, strength: theme.weight, tint: Theme.accent) { lookUp(theme.phrase) }
                                    }
                                }
                            }
                        }
                        if !detail.motifs.isEmpty {
                            labelled("Images and motifs") {
                                FlowLayout {
                                    ForEach(detail.motifs, id: \.self) { motif in
                                        WordChip(title: motif, tint: Color(Theme.highlighter(2))) { lookUp(motif) }
                                    }
                                }
                            }
                        }
                        if !detail.mood.isEmpty {
                            labelled("Feels") {
                                FlowLayout {
                                    ForEach(detail.mood, id: \.self) { mood in
                                        WordChip(title: mood, tint: Color(Theme.highlighter(4))) { lookUp(mood) }
                                    }
                                }
                            }
                        }
                        let musical = detail.relatives.filter { $0.isMusical(from: work) }
                        if !musical.isEmpty {
                            // Who sampled, covered or borrowed from whom, across cultures first.
                            labelled(detail.timesTaken > 0 ? "Sampled and borrowed · taken \(detail.timesTaken) time\(detail.timesTaken == 1 ? "" : "s")" : "Sampled and borrowed") {
                                ForEach(musical) { relative in relativeRow(relative) }
                            }
                        }
                        let others = detail.relatives.filter { !$0.isMusical(from: work) }
                        if !others.isEmpty {
                            labelled("Relatives") {
                                ForEach(others) { relative in relativeRow(relative) }
                            }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .background(Theme.ink)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !trail.isEmpty {
                        Button("Back", systemImage: "chevron.left") { work = trail.removeLast() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: work.id) {
                detail = await model.culture.detail(work.id, kinship: model.cultureWeights.kinship)
                carried = await model.culture.carried(work.id)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func relativeRow(_ relative: WorkDetail.Relative) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                trail.append(work)
                work = relative.work
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relative.work.caption).font(.subheadline.weight(.semibold)).foregroundStyle(relative.work.culture.tint)
                        Text("\(relative.relation) · \(relative.work.culture.name) \(relative.work.kind.label)\(relative.work.maker.isEmpty || relative.work.kind != .song ? "" : " · " + relative.work.maker)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // How strong the kinship is, from an acknowledged remake down to a shared theme.
                    Capsule().fill(Color.white.opacity(0.12)).frame(width: 44, height: 5)
                        .overlay(alignment: .leading) { Capsule().fill(Theme.accent).frame(width: 44 * relative.strength, height: 5) }
                }
            }
            .buttonStyle(.plain)
            if let themes = carried[relative.work.id] {
                Text("carried across: " + themes.joined(separator: ", ")).font(.caption2).foregroundStyle(Theme.accent.opacity(0.8))
            }
            if let source = relative.source {
                // Credit where the link came from, linked where the source asks for it.
                if let url = source.url {
                    Link("via \(source.name)", destination: url).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("via \(source.name)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(work.title).font(.title2.bold())
            if !work.nativeTitle.isEmpty {
                Text(work.nativeTitle).font(.title3).foregroundStyle(.secondary)
            }
            Text([work.yearLabel, "\(work.culture.name) \(work.kind.label)", work.maker.isEmpty ? nil : work.maker].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(work.culture.tint)
            if let detail {
                if !detail.summary.isEmpty { Text(detail.summary).font(.subheadline).foregroundStyle(.secondary) }
                if !detail.canon.isEmpty {
                    Text(detail.canon.joined(separator: " · ")).font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func lookUp(_ phrase: String) {
        model.labQuery = AppModel.LabQuery(text: phrase, language: .english)
        model.tab = .lab
        dismiss()
    }
}
