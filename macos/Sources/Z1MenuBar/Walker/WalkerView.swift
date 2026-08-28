import SwiftUI

/// The man, drawn as diamond dots.
///
/// The popover hero hosts a small side-on figure (`MenuBarView` uses pitch 2,
/// 44 × 52 pt). Legs follow belt speed; a stopped belt pauses him, then the
/// idle fidgets in `WalkerState`. `WalkerPreviewStrip` is the contact sheet
/// and is not shipped in the popover.
struct WalkerView: View {
    /// Straight off the treadmill.
    var beltRunning: Bool
    var speedKmh: Double
    /// Seconds since the person last touched anything.
    var secondsIdle: Double = 0

    /// Cell pitch in points. The figure is 22 x 26 cells, so 3 pt gives a
    /// 66 x 78 pt man.
    var pitch: CGFloat = 3

    /// Fixed by default, so two walkers on screen are in step and so anything
    /// that renders him is reproducible.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    @State private var state: WalkerState
    @State private var lastTick: Date?

    init(
        beltRunning: Bool,
        speedKmh: Double,
        secondsIdle: Double = 0,
        pitch: CGFloat = 3,
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) {
        self.beltRunning = beltRunning
        self.speedKmh = speedKmh
        self.secondsIdle = secondsIdle
        self.pitch = pitch
        self.seed = seed
        _state = State(initialValue: WalkerState(seed: seed))
    }

    private var size: CGSize {
        CGSize(
            width: CGFloat(WalkerSprites.width) * pitch,
            height: CGFloat(WalkerSprites.height) * pitch
        )
    }

    var body: some View {
        // 30 Hz is far more than the man needs -- he changes frame about seven
        // times a second at a walk -- but the driver has to tick faster than
        // the animation to keep the cadence easing smooth.
        Group {
            if beltRunning {
                TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { context in
                    WalkerFrameView(frame: state.frame, pitch: pitch)
                        .onChange(of: context.date) { _, now in
                            tick(to: now)
                        }
                }
            } else {
                WalkerFrameView(frame: state.frame, pitch: pitch)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// The only place a clock touches the walker. `WalkerState` itself never
    /// asks what time it is -- it is handed `dt`, which is what makes an
    /// evening's worth of behaviour runnable in a test loop.
    private func tick(to now: Date) {
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        guard dt > 0 else { return }
        state.advance(
            dt: dt,
            input: WalkerInput(
                beltRunning: beltRunning,
                speedKmh: speedKmh,
                hour: Calendar.current.component(.hour, from: now),
                secondsIdle: secondsIdle
            )
        )
    }
}

/// One frame of the man, and nothing else. Stateless, so it can be used for
/// contact sheets, previews and tests without dragging a clock along.
struct WalkerFrameView: View {
    var frame: WalkerFrame
    var pitch: CGFloat = 3
    var ink: Color = Z1.ink

    /// The dither dot's alpha. It is doing two jobs: half-toning the far arm
    /// and leg so the side view reads as having depth, and thinning the
    /// trailing edge so the figure dissolves rather than being outlined.
    var ditherAlpha: Double = 0.45

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .frame(
            width: CGFloat(WalkerSprites.width) * pitch,
            height: CGFloat(WalkerSprites.height) * pitch
        )
    }

    private func draw(in context: inout GraphicsContext) {
        // Solid dots run slightly past their cell so orthogonal neighbours
        // overlap and the body reads as mass. A diamond inscribed exactly in
        // its cell covers only half of it and meets its neighbour at a single
        // point -- at 100% the man came out as loose weave rather than a
        // figure. The dither dot stays just under the pitch so it still
        // connects along a limb but reads lighter.
        let solid = pitch * 1.06
        let dither = pitch * 0.93
        let solidInk = GraphicsContext.Shading.color(ink)
        let ditherInk = GraphicsContext.Shading.color(ink.opacity(ditherAlpha))

        for (row, line) in frame.rows.enumerated() {
            for (column, cell) in line.enumerated() where cell != "0" {
                let centre = CGPoint(
                    x: (CGFloat(column) + 0.5) * pitch,
                    y: (CGFloat(row) + 0.5) * pitch
                )
                let isSolid = cell == "2"
                context.fill(
                    Self.diamond(at: centre, width: isSolid ? solid : dither),
                    with: isSolid ? solidInk : ditherInk
                )
            }
        }
    }

    /// A dot rotated 45 degrees. Diamonds rather than squares or circles
    /// because a diamond screen is the least conspicuous to the eye, and
    /// because diamonds join their neighbours gradually as they grow instead
    /// of snapping shut at 50% the way round dots do -- which is what keeps
    /// the dissolve looking like a ramp rather than a step.
    static func diamond(at centre: CGPoint, width: CGFloat) -> Path {
        let r = width / 2
        var path = Path()
        path.move(to: CGPoint(x: centre.x, y: centre.y - r))
        path.addLine(to: CGPoint(x: centre.x + r, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x, y: centre.y + r))
        path.addLine(to: CGPoint(x: centre.x - r, y: centre.y))
        path.closeSubpath()
        return path
    }
}

/// Every frame at once, for judging the set. Not shipped in the popover.
struct WalkerPreviewStrip: View {
    var pitch: CGFloat = 5

    private let groups: [(String, [WalkerFrame])] = [
        ("walk", WalkerFrame.walkCycle),
        ("idle", [.stand, .standBreath, .watch, .drink, .typeA, .typeB]),
        ("seated", [.sit, .sleep]),
        ("rising", [.rise1, .rise2, .rise3, .stand]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.0) { title, frames in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(Z1Type.regular(10))
                        .foregroundStyle(Z1.dim)
                    HStack(spacing: 10) {
                        ForEach(frames, id: \.self) { frame in
                            WalkerFrameView(frame: frame, pitch: pitch)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Z1.canvas)
    }
}
