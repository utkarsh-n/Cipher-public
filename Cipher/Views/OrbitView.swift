import SwiftData
import SwiftUI

extension OrbitDirection {
    var tint: Color {
        switch self {
        case .home: .white
        case .sound: Theme.accent
        case .recut: Color(Theme.highlighter(5))
        case .hinge: Color(Theme.highlighter(2))
        case .meaning: Color(Theme.highlighter(4))
        case .roots: Color(Theme.highlighter(7))
        case .culture: Color(Theme.highlighter(1))
        case .tongues: Color(Theme.highlighter(3))
        case .leap: Color(Theme.highlighter(6))
        }
    }
}

/// Measured label widths, cached, so Devanagari and Gujarati get capsules that fit.
final class LabelMeasure {
    private var cache: [String: CGFloat] = [:]

    /// The width at 12 pt, scaled: system text widths grow almost exactly with size, so one
    /// measurement per text and weight serves every depth the sphere draws it at.
    func width(_ text: String, size: CGFloat, weight: UIFont.Weight = .medium) -> CGFloat {
        guard size.isFinite, size > 0 else { return 0 }
        let key = "\(weight.rawValue)|\(text)"
        if let known = cache[key] { return known * size / 12 }
        if cache.count > 4000 { cache.removeAll() }
        let measured = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: weight)]).width
        cache[key] = measured
        return measured * size / 12
    }
}

/// One node on screen.
struct PlacedNode {
    let node: OrbitNode
    let point: CGPoint
    let depth: Double
    let rect: CGRect
    /// What the capsule says, and the Roman spelling beside it when the word is in another script.
    let title: String
    let roman: String
    /// How far into its arrival the node is, 0...1: it shoots out from the centre and pops.
    var pop: Double = 1
    /// Where it is right now on its way out, and how big: at `point`, full size, once landed.
    var tip: CGPoint = .zero
    var scale: Double = 1
    /// Drawn as a dot rather than a label: behind the sphere, or under a stronger label.
    var dot = false

    /// The capsule as drawn this frame, which is what a finger can hit.
    var drawn: CGRect {
        CGRect(x: tip.x - rect.width * scale / 2, y: tip.y - rect.height * scale / 2, width: rect.width * scale, height: rect.height * scale)
    }
}

/// The sphere as a sheet over the editor or the Lab: the panel, with a seed field when it is
/// empty, half-height so the bar stays editable underneath, or full screen.
struct OrbitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with text to drop into the bar being written.
    var onInsert: ((String) -> Void)?
    /// Called with the whole chain to write into the lyric (over the line it came from, or at the caret).
    var onChain: ((String) -> Void)?

    @State private var showWeights = false
    @State private var showHistory = false
    @State private var seed = ""
    @State private var detent: PresentationDetent = .medium

    private var orbit: OrbitModel { model.orbit }

    var body: some View {
        NavigationStack {
            OrbitPanel(showWeights: showWeights, onInsert: onInsert, onChain: chainHandler, onLeave: { dismiss() }) {
                emptyState
            }
            .navigationTitle(orbit.isEmpty ? "Orbit" : orbit.centre)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Show weights", systemImage: "number", isOn: $showWeights)
                        Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        if !orbit.isEmpty {
                            Button("Copy chain", systemImage: "doc.on.doc") { UIPasteboard.general.string = orbit.chainText }
                            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { orbit.clear() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(detent == .large ? "Smaller" : "Full screen", systemImage: detent == .large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        detent = detent == .large ? .medium : .large
                    }
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showHistory) { ChainHistoryView(onLeave: { dismiss() }) }
    }

    /// Writing the chain back closes the sheet.
    private var chainHandler: ((String) -> Void)? {
        guard let onChain else { return nil }
        return { chain in
            onChain(chain)
            dismiss()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagonpath").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Stand inside a word").font(.title3.weight(.semibold))
            Text("Everything one step away, in every direction you move: sound, hinges, meaning, culture, your other tongues, and the leaps. Tap a word to step to it; the chain builds as you go.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                TextField("A word or phrase", text: $seed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(start)
                Button("Go", action: start).buttonStyle(.glassProminent).tint(Theme.accent).disabled(seed.isEmpty)
            }
        }
        .padding(20)
    }

    private func start() {
        guard !seed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        orbit.begin(seed, model: model)
        seed = ""
    }
}

/// The sphere and everything around it: the chain walked so far, the sphere per word of a
/// phrase, the compass, a node's card up close, and what to do with the chain. The centre word
/// has everything a step away placed around it by direction, like standing inside a street view
/// of the word. Drag to look around, tap a word to step to it, pinch to zoom. Every node sits at
/// the end of its vector; the weights can be shown. Shown in the Sphere tab and in the sheet.
struct OrbitPanel<Empty: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    let showWeights: Bool
    /// Without the action bar, for when the keyboard would cover it anyway.
    var compact = false
    var onInsert: ((String) -> Void)?
    var onChain: ((String) -> Void)?
    /// Called once the chain has gone somewhere else, so a sheet can close.
    var onLeave: (() -> Void)?
    /// Called when the sphere is touched, so a screen can put its keyboard away.
    var onTouch: (() -> Void)?
    /// What stands in while there is no centre.
    @ViewBuilder let empty: () -> Empty

    /// Facing the Sound sector to begin with (home sits at longitude 0, sound at 45°).
    @State private var yaw: Double = -.pi / 4
    @State private var zoom: Double = 1
    // Gesture state resets on end and on cancel, which a sheet's own pan can cause.
    @GestureState private var dragging = false
    @GestureState private var pinching = false
    @State private var lastDrag: CGFloat = 0
    @State private var lastPinch: Double = 1
    @State private var selected: OrbitNode?
    @State private var facing: OrbitDirection = .sound
    @State private var measure = LabelMeasure()
    /// When each node on the sphere arrived, so new ones pop out of the centre.
    @State private var births: [String: Date] = [:]
    /// The centre the births belong to; a new centre starts afresh.
    @State private var bornFor = ""
    @State private var arrivals = 0
    @State private var popping = false
    /// Turned to face the writer's favourite direction once, when the panel first appears.
    @State private var settled = false

    private var orbit: OrbitModel { model.orbit }

    var body: some View {
        VStack(spacing: 0) {
            if orbit.isEmpty {
                empty()
            } else {
                chainBar
                if !orbit.pins.isEmpty { pinnedRow }
                if !orbit.parts.isEmpty { splitPicker }
                sphere
                // Up close, the node's own card stands where the compass was.
                if let selected { detail(for: selected) } else { compass }
                if !compact { actionBar }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ink)
        .alert("Claude couldn't answer", isPresented: Binding(get: { orbit.problem != nil }, set: { if !$0 { orbit.problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(orbit.problem ?? "")
        }
        .onChange(of: orbit.centre) { selected = nil; lastDrag = 0; lastPinch = 1 }
        .onChange(of: dragging) { if !dragging { lastDrag = 0; facing = nearestDirection() } }
        .onChange(of: pinching) { if !pinching { lastPinch = 1 } }
        .onChange(of: orbit.nodes.map(\.id), initial: true) { _, ids in arrive(ids) }
        .onAppear {
            // The sphere opens facing the way the writer usually walks.
            guard !settled else { return }
            settled = true
            if let favourite = model.favouriteDirections.first {
                yaw = -favourite.longitude * .pi / 180
                facing = favourite
            }
        }
        .task(id: arrivals) {
            // The clock runs while the newest nodes are still popping, then rests.
            guard popping else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            popping = false
        }
    }

    /// New nodes are stamped with now. A node that leaves and comes back (the split picker
    /// turning between a phrase and its words) keeps its stamp; a new centre forgets them all.
    private func arrive(_ ids: [String]) {
        if let selected, !ids.contains(selected.id) { self.selected = nil }
        let now = Date.now
        if bornFor != orbit.centre {
            births = [:]
            bornFor = orbit.centre
        }
        var fresh = false
        for id in ids where births[id] == nil {
            births[id] = now
            fresh = true
        }
        if fresh {
            popping = true
            arrivals += 1
        }
    }

    // MARK: Chain

    /// The steps taken, as a trail of chips; tap one to go back to it.
    private var chainBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(orbit.trail.enumerated()), id: \.offset) { index, step in
                        Button {
                            orbit.rewind(to: index, model: model)
                        } label: {
                            stepLabel(step, strong: false)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    stepLabel(orbit.centre, strong: true).id("centre")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: orbit.centre) { withAnimation { proxy.scrollTo("centre", anchor: .trailing) } }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The words pinned on this chain. Every node leading toward one carries a pin on the
    /// sphere; tap a pin to step straight to it.
    private var pinnedRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent)
                ForEach(orbit.pins, id: \.self) { word in
                    Button {
                        orbit.go(to: word, model: model)
                    } label: {
                        Text(shown(word, roman: orbit.romans[word] ?? ""))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unpin", systemImage: "pin.slash") { orbit.unpin(word, model: model) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A phrase splits into a sphere per word: "Super Man" is Super, and Man, and both.
    private var splitPicker: some View {
        Picker("Sphere", selection: Binding(get: { orbit.part }, set: { orbit.part = $0 })) {
            Text(shown(orbit.centre, roman: orbit.orbit?.roman ?? "")).tag(0)
            ForEach(Array(orbit.parts.enumerated()), id: \.offset) { index, part in
                Text(shown(part.word, roman: part.orbit.roman)).tag(index + 1)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .onChange(of: orbit.part) { selected = nil }
    }

    /// A word the way the writer wants Hindi and Gujarati written: its script, its Roman
    /// spelling, or both side by side.
    private func shown(_ word: String, roman: String) -> String {
        guard !roman.isEmpty else { return word }
        switch model.scriptDisplay {
        case .native: return word
        case .roman: return roman
        case .both: return word + " " + roman
        }
    }

    private func stepLabel(_ step: String, strong: Bool) -> some View {
        let roman = orbit.romans[step] ?? ""
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.scriptDisplay == .roman && !roman.isEmpty ? roman : step)
                    .font(strong ? .subheadline.weight(.bold) : .subheadline)
                    .foregroundStyle(strong ? Theme.ink : .primary)
                if model.scriptDisplay == .both, !roman.isEmpty {
                    Text(roman)
                        .font(.caption2)
                        .foregroundStyle(strong ? Theme.ink.opacity(0.7) : Color.secondary)
                }
            }
            .lineLimit(1)
            // A thread of colour: cold blue to warm lime, by how the word reads.
            Capsule()
                .fill(orbit.feel[step].map { Color(hue: 0.62 - 0.42 * ($0 + 1) / 2, saturation: 0.8, brightness: 0.95) } ?? Color.clear)
                .frame(width: 18, height: 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(strong ? .regular.tint(Theme.accent) : .regular, in: .capsule)
    }

    // MARK: Sphere

    private var sphere: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !popping)) { timeline in
            SphereView(nodes: orbit.nodes, centre: orbit.displayedCentre, centreRoman: orbit.displayedRoman, echoes: orbit.echoes,
                       attracted: orbit.attracted, favourites: Array(model.favouriteDirections.prefix(2)), yaw: yaw, zoom: zoom,
                       selectedID: selected?.id, showWeights: showWeights, display: model.scriptDisplay, loading: orbit.isLoading,
                       measure: measure, births: births, now: timeline.date) { node in
                onTouch?()
                guard let node else {
                    selected = nil
                    return
                }
                if selected?.id == node.id {
                    orbit.go(to: node.text, via: node.direction, model: model)
                    selected = nil
                } else {
                    selected = node
                    orbit.bridge(for: node, model: model)
                }
            }
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .clipped()
        // Sideways looks around; up and down is left to the sheet, so it still swipes away.
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                if lastDrag == 0 { onTouch?() }
                let delta = value.translation.width - lastDrag
                lastDrag = value.translation.width
                yaw += Double(delta) / 140
            })
        .simultaneousGesture(MagnifyGesture()
            .updating($pinching) { _, state, _ in state = true }
            .onChanged { value in
                zoom = max(0.7, min(1.8, zoom * value.magnification / lastPinch))
                lastPinch = value.magnification
            })
    }

    private func nearestDirection() -> OrbitDirection {
        var best = OrbitDirection.sound
        var bestScore = -2.0
        for direction in OrbitDirection.allCases {
            let z = cos(direction.longitude * .pi / 180 + yaw)
            if z > bestScore { bestScore = z; best = direction }
        }
        return best
    }

    /// The directions around the edge; tap one to turn and face it.
    private var compass: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(OrbitDirection.allCases) { direction in
                    let count = orbit.nodes(in: direction).count
                    Button {
                        if direction == .leap, count == 0, model.hasAPIKey { orbit.leap(model: model) }
                        // Turn the short way round.
                        let target = -direction.longitude * .pi / 180
                        let difference = atan2(sin(target - yaw), cos(target - yaw))
                        withAnimation(.spring(duration: 0.5)) { yaw += difference }
                        facing = direction
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: direction.symbol).font(.caption2)
                            Text(direction.label).font(.caption.weight(.semibold))
                            if direction == .leap, count == 0 {
                                Text(orbit.isLeaping ? "…" : model.hasAPIKey ? "ask" : "key").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(facing == direction ? Theme.ink : direction.tint)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .glassEffect(facing == direction ? .regular.tint(direction.tint) : .regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What to do with the chain: step back, put it in the bar, or start a song from it.
    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Back", systemImage: "arrow.uturn.backward") { orbit.back(model: model) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .disabled(orbit.trail.isEmpty)
            // The step Back undid, until another step replaces it.
            if let next = orbit.forwardStep {
                Button {
                    orbit.forward(model: model)
                } label: {
                    Label(next, systemImage: "arrow.uturn.forward").lineLimit(1)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: 130)
            }
            if let onChain {
                Button {
                    onChain(orbit.chainText)
                } label: {
                    Label(orbit.source == nil ? "Use in bar" : "Write it back", systemImage: "text.insert").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            } else {
                Button {
                    sendToEditor()
                } label: {
                    Label("Send to editor", systemImage: "pencil.line").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// A new song that opens with the chain as its first line.
    private func sendToEditor() {
        let song = Song(title: orbit.centre, text: orbit.chainText)
        context.insert(song)
        model.openSong = song
        model.tab = .write
        onLeave?()
    }

    /// One node up close: why it is here, its pull in every direction, and the two things to do with it.
    private func detail(for node: OrbitNode) -> some View {
        // The headline follows the script setting; the other form, or the meaning, sits beside it.
        let roman = node.roman
        let headline = model.scriptDisplay == .roman && !roman.isEmpty ? roman : node.text
        let aside = roman.isEmpty ? node.aside : model.scriptDisplay == .roman ? node.text : model.scriptDisplay == .both ? roman : node.gloss
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline).font(.headline)
                if !aside.isEmpty { Text(aside).font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                Text(node.why).font(.caption).foregroundStyle(node.direction.tint).lineLimit(2).multilineTextAlignment(.trailing)
            }
            if let bridge = orbit.bridges[node.id], !bridge.isEmpty {
                // The unwritten step between here and there.
                Text("via \(bridge.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(Array(zip(OrbitDirection.measured, node.vector)), id: \.0) { direction, value in
                    VStack(spacing: 3) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 5)
                            .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(direction.tint).frame(width: g.size.width * value) } }
                        Text(String(format: "%@ %.2f", direction.label.lowercased(), value)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Step here", systemImage: "arrow.right.circle.fill") { orbit.go(to: node.text, via: node.direction, model: model); selected = nil }
                    .buttonStyle(.glassProminent).tint(node.direction.tint)
                Button(orbit.isPinned(node.text) ? "Unpin" : "Pin", systemImage: orbit.isPinned(node.text) ? "pin.slash" : "pin") {
                    if orbit.isPinned(node.text) { orbit.unpin(node.text, model: model) } else { orbit.pin(node.text, roman: node.roman, model: model) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                if let onInsert {
                    Button("Drop in bar", systemImage: "text.insert") { onInsert(node.text) }.buttonStyle(.glass)
                }
                Spacer()
                if orbit.attracted.contains(node.id) {
                    Label("toward a pin", systemImage: "pin.fill").font(.caption).foregroundStyle(Theme.accent)
                } else if orbit.echoes.contains(node.id) {
                    Label("echoes the chain", systemImage: "arrow.uturn.backward").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The drawing itself. Animatable on yaw, so a compass tap turns the sphere rather than snapping it.
private struct SphereView: View, Animatable {
    let nodes: [OrbitNode]
    let centre: String
    let centreRoman: String
    let echoes: Set<String>
    /// Nodes leading toward a pinned word.
    let attracted: Set<String>
    /// The directions the writer walks most: they show a few more nodes.
    let favourites: [OrbitDirection]
    var yaw: Double
    let zoom: Double
    /// A slight tilt, so the sphere reads as a sphere.
    private let pitch = 0.15
    let selectedID: String?
    let showWeights: Bool
    /// How Hindi and Gujarati words are written: their script, Roman letters, or both.
    let display: ScriptDisplay
    let loading: Bool
    let measure: LabelMeasure
    /// When each node arrived, and the time now: a node still arriving is drawn mid-pop.
    let births: [String: Date]
    let now: Date
    /// A tap on a node, or on nothing.
    let onTap: (OrbitNode?) -> Void

    var animatableData: Double {
        get { yaw }
        set { yaw = newValue }
    }

    private static let caps: [OrbitDirection: Int] = [.home: 10, .sound: 16, .recut: 12, .hinge: 14, .meaning: 14, .roots: 12, .culture: 12, .tongues: 12, .leap: 12]
    /// How long a node takes to arrive, in seconds.
    private static let arrival = 0.45

    var body: some View {
        GeometryReader { geometry in
            let placed = place(in: geometry.size)
            ZStack {
                Canvas { context, size in
                    draw(placed, in: context, size: size)
                }
                if loading {
                    ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in onTap(hit(location, in: placed)) }
        }
    }

    /// The label under the finger, front-most first; failing that a visible dot close by.
    /// Both are tested where they are drawn this frame, mid-pop included.
    private func hit(_ location: CGPoint, in placed: [PlacedNode]) -> OrbitNode? {
        // A selected node is drawn as a full capsule even where it would be a dot; it is hit as one.
        for item in placed.reversed() where (!item.dot || item.node.id == selectedID) && item.drawn.insetBy(dx: -4, dy: -4).contains(location) {
            return item.node
        }
        let dots = placed.filter { $0.dot && $0.depth > -0.1 }
        if let near = dots.min(by: { hypot($0.tip.x - location.x, $0.tip.y - location.y) < hypot($1.tip.x - location.x, $1.tip.y - location.y) }),
           hypot(near.tip.x - location.x, near.tip.y - location.y) < 14 {
            return near.node
        }
        return nil
    }

    /// Eases: the vector shoots out and settles; the label overshoots a little and springs back.
    private static func reach(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func spring(_ t: Double) -> Double {
        let u = t - 1
        return 1 + 2.70158 * u * u * u + 1.70158 * u * u
    }

    private func draw(_ placed: [PlacedNode], in context: GraphicsContext, size: CGSize) {
        let centrePoint = CGPoint(x: size.width / 2, y: size.height / 2)
        // Vectors first, back to front, so labels paint over them.
        for item in placed where !item.dot {
            let strength = item.node.weight
            let end = item.tip
            var line = Path()
            line.move(to: centrePoint)
            line.addLine(to: end)
            context.stroke(line, with: .color(item.node.direction.tint.opacity(0.08 + 0.3 * strength * (0.5 + 0.5 * item.depth))), lineWidth: 0.5 + 1.5 * strength)
            if showWeights, item.pop >= 1 {
                let mid = CGPoint(x: (centrePoint.x + end.x) / 2, y: (centrePoint.y + end.y) / 2)
                context.draw(Text(String(format: "%.2f", strength)).font(.system(size: 8, design: .monospaced)).foregroundStyle(item.node.direction.tint.opacity(0.7)), at: mid)
            }
        }
        for item in placed {
            let front = (item.depth + 1) / 2
            let alpha = (0.2 + 0.8 * front) * min(1, item.pop * 1.6)
            let isSelected = selectedID == item.node.id
            let at = item.tip
            if item.dot && !isSelected {
                // Behind, or under a stronger label: a point of light, still there to turn to.
                let radius = 2.5 * Self.reach(item.pop)
                context.fill(Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2)), with: .color(item.node.direction.tint.opacity(0.25 + 0.5 * front)))
                continue
            }
            // Mid-pop the capsule is drawn smaller about its tip, overshooting once as it lands.
            let scale = item.scale
            let box = item.drawn
            let capsule = Path(roundedRect: box, cornerRadius: box.height / 2)
            context.fill(capsule, with: .color(item.node.direction.tint.opacity(isSelected ? 0.9 : 0.1 + 0.12 * front)))
            context.stroke(capsule, with: .color(item.node.direction.tint.opacity(isSelected ? 1 : 0.25 * alpha)), lineWidth: isSelected ? 1.5 : 0.5)
            if echoes.contains(item.node.id), item.pop >= 1 {
                context.fill(Path(ellipseIn: CGRect(x: box.maxX - 5, y: box.minY - 2, width: 7, height: 7)), with: .color(Color.white.opacity(alpha)))
            }
            if attracted.contains(item.node.id), item.pop >= 1 {
                // A pin at the corner: this way lies one of the pinned words.
                context.draw(Text(Image(systemName: "pin.fill")).font(.system(size: 8)).foregroundStyle(Theme.accent.opacity(0.4 + 0.6 * alpha)),
                             at: CGPoint(x: box.minX + 3, y: box.minY))
            }
            let fontSize = (10 + 5 * front) * scale
            guard fontSize >= 1 else { continue }
            let ink = isSelected ? Theme.ink : Color.white.opacity(alpha)
            var label = Text(item.title).font(.system(size: fontSize, weight: isSelected ? .bold : .medium)).foregroundStyle(ink)
            if !item.roman.isEmpty {
                // The Roman spelling rides along, smaller, so the script is never read alone.
                label = label + Text(" " + item.roman).font(.system(size: fontSize * 0.8, weight: .regular)).foregroundStyle(isSelected ? Theme.ink.opacity(0.7) : Color.white.opacity(alpha * 0.7))
            }
            context.draw(label, at: at)
        }
        // The centre word, in front of everything.
        let home = badge(centrePoint)
        context.fill(Path(roundedRect: home, cornerRadius: 16), with: .color(Theme.ink.opacity(0.9)))
        context.stroke(Path(roundedRect: home, cornerRadius: 16), with: .color(Theme.accent), lineWidth: 1.5)
        // Fixed sizes, the same ones the badge was measured with.
        var title = Text(centre).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.white)
        if !centreRoman.isEmpty, display == .both {
            title = title + Text(" " + centreRoman).font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.7))
        } else if !centreRoman.isEmpty, display == .roman {
            title = Text(centreRoman).font(.system(size: 20, weight: .bold)).foregroundStyle(Color.white)
        }
        context.draw(title, at: centrePoint)
    }

    private func badge(_ centrePoint: CGPoint) -> CGRect {
        var width = measure.width(display == .roman && !centreRoman.isEmpty ? centreRoman : centre, size: 20, weight: .bold) + 28
        if !centreRoman.isEmpty, display == .both { width += measure.width(" " + centreRoman, size: 15, weight: .regular) }
        return CGRect(x: centrePoint.x - width / 2, y: centrePoint.y - 17, width: width, height: 34)
    }

    /// What a node's capsule says, given how the writer wants Hindi and Gujarati written.
    private func wording(_ node: OrbitNode) -> (title: String, roman: String) {
        guard !node.roman.isEmpty else { return (node.text, "") }
        switch display {
        case .native: return (node.text, "")
        case .roman: return (node.roman, "")
        case .both: return (node.text, node.roman)
        }
    }

    /// Where every node sits on screen for the current view of the sphere.
    private func place(in size: CGSize) -> [PlacedNode] {
        let centrePoint = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.46 * zoom
        let groups = Dictionary(grouping: nodes, by: \.direction)
        var placed: [PlacedNode] = []
        for direction in OrbitDirection.allCases {
            let cap = (Self.caps[direction] ?? 12) + (favourites.contains(direction) ? 4 : 0)
            let members = (groups[direction] ?? []).sorted { $0.weight > $1.weight }.prefix(cap)
            guard !members.isEmpty else { continue }
            let base = direction.longitude * .pi / 180
            for (rank, node) in members.enumerated() {
                // Within its sector the strongest sit at eye level, weaker ones climb and dive.
                let row = (rank + 1) / 2
                let side = rank % 2 == 0 ? 1.0 : -1.0
                let latitude = side * min(1.05, Double(row) * 0.17)
                let longitude = base + Double(rank % 3 - 1) * 0.42 + Double(rank % 5 - 2) * 0.1
                let r = radius * (1 - 0.3 * node.weight)
                var x = cos(latitude) * sin(longitude)
                let y = sin(latitude)
                var z = cos(latitude) * cos(longitude)
                // Look around: yaw about the vertical, then pitch about the horizontal.
                (x, z) = (x * cos(yaw) + z * sin(yaw), -x * sin(yaw) + z * cos(yaw))
                let y2 = y * cos(pitch) - z * sin(pitch)
                let z2 = y * sin(pitch) + z * cos(pitch)
                let front = (z2 + 1) / 2
                let fontSize = 10 + 5 * front
                let (title, roman) = wording(node)
                var width = measure.width(title, size: fontSize) + 16
                if !roman.isEmpty { width += measure.width(" " + roman, size: fontSize * 0.8, weight: .regular) }
                let height = fontSize + 10
                let point = CGPoint(x: centrePoint.x + x * r, y: centrePoint.y - y2 * r)
                let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
                let age = now.timeIntervalSince(births[node.id] ?? .distantPast)
                let pop = max(0, min(1, age / Self.arrival))
                let reach = Self.reach(pop)
                let tip = CGPoint(x: centrePoint.x + (point.x - centrePoint.x) * reach, y: centrePoint.y + (point.y - centrePoint.y) * reach)
                placed.append(PlacedNode(node: node, point: point, depth: z2, rect: rect, title: title, roman: roman, pop: pop, tip: tip, scale: max(0.02, Self.spring(pop))))
            }
        }
        placed.sort { $0.depth < $1.depth }
        // Labels only on the facing half, never on top of a stronger one, and never over the centre word.
        var taken: [CGRect] = [badge(centrePoint)]
        for index in placed.indices.reversed() {
            let item = placed[index]
            if item.depth < -0.1 || taken.contains(where: { $0.intersects(item.rect.insetBy(dx: -2, dy: -2)) }) {
                placed[index].dot = true
            } else {
                taken.append(item.rect)
            }
        }
        return placed
    }
}
