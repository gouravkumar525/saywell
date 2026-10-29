import AppKit
import LocalFlowCore
import SwiftUI

/// Draws Sprig every frame from its pose (C3). Port of the renderer in
/// sprig_character.md, plus Saywell's two gestures (listening, writing).
/// Drawn for a dark background (the notch), so things outside the body are light.
struct SprigView: View {
    let engine: SprigEngine
    /// Body half-width as a fraction of min(width, height).
    var scale: Double = 0.2
    /// Ground line as a fraction of the height.
    var ground: Double = 0.82
    var paused = false
    /// Pointer direction (-1...1, y down) relative to Sprig, read every frame.
    var pointer: () -> (Double, Double) = { (0, 0) }
    /// Voice level 0...1, read every frame.
    var level: () -> Double = { 0 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { timeline in
            Canvas { context, size in
                engine.pointer = pointer()
                engine.targetLevel = level()
                engine.update(now: timeline.date.timeIntervalSinceReferenceDate)
                SprigRenderer(engine: engine, size: size, scale: scale, ground: ground).draw(in: context)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.poke() }
        .accessibilityLabel("Sprig, \(engine.stateConfig.label)")
    }
}

/// Still images of Sprig for the menu bar and the closed notch.
enum SprigIcon {
    private static var cache: [String: NSImage] = [:]

    /// Sprig in `state`, settled (entrance moves finished), `points` square.
    @MainActor
    static func image(state: String, points: CGFloat = 18) -> NSImage? {
        let key = "\(state)@\(points)"
        if let cached = cache[key] { return cached }
        let engine = SprigEngine(state: "idle", reducedMotion: true, random: { 0.5 })
        engine.update(now: 0)
        engine.setState(state)
        var t = 0.0
        for _ in 0..<150 { t += 1.0 / 60; engine.update(now: t) }
        let view = Canvas { context, size in
            SprigRenderer(engine: engine, size: size, scale: 0.29, ground: 0.95, particles: false).draw(in: context)
        }
        .frame(width: points, height: points)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.accessibilityDescription = "Saywell"
        cache[key] = image
        return image
    }
}

struct SprigRenderer {
    let engine: SprigEngine
    let size: CGSize
    let scale: Double
    let ground: Double
    var particles = true

    private static let ink = Color(red: 0x1E / 255, green: 0x25 / 255, blue: 0x30 / 255)
    private static let stem = Color(red: 0x3E / 255, green: 0x8F / 255, blue: 0x57 / 255)
    private static let bigLeaf = Color(red: 0x5D / 255, green: 0xBB / 255, blue: 0x75 / 255)
    private static let smallLeaf = Color(red: 0x4D / 255, green: 0xA8 / 255, blue: 0x66 / 255)
    private static let pink = Color(red: 0xE8 / 255, green: 0x45 / 255, blue: 0x6B / 255)
    /// Marks outside the body (z, arcs, notes) on the dark notch.
    private static let light = Color(red: 0xC9 / 255, green: 0xD3 / 255, blue: 0xDE / 255)

    private var p: SprigPose { engine.pose }
    private var cfg: SprigStateConfig { engine.stateConfig }
    private var t: Double { engine.time }

    private func color(_ mixWith: (Double, Double, Double)? = nil, _ amount: Double = 0, alpha: Double = 1) -> Color {
        var c = engine.color
        if let m = mixWith {
            c = (c.r + (m.0 - c.r) * amount, c.g + (m.1 - c.g) * amount, c.b + (m.2 - c.b) * amount)
        }
        return Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255, opacity: alpha)
    }

    func draw(in base: GraphicsContext) {
        let R = Double(min(size.width, size.height)) * scale
        let W = R, H = R * 1.9
        let cx = Double(size.width) / 2, gy = Double(size.height) * ground
        let br = cfg.breathes ? sin(t * 1.5) * 0.035 : sin(t * 2.2) * 0.012
        let sx = p.sx * (1 - br * 0.6), sy = p.sy * (1 + br)

        var c = base
        c.translateBy(x: cx + p.ox * R, y: gy + p.oy * R)          // origin at the base: squash stays grounded
        c.rotate(by: .radians(p.tilt + (cfg.wiggle ? sin(t * 13) * 0.015 : 0)))
        c.translateBy(x: 0, y: -H / 2)
        c.rotate(by: .radians(p.spin))                                 // spin around the body centre
        c.translateBy(x: 0, y: H / 2)
        c.scaleBy(x: sx, y: sy)

        drawSprout(c, W: W, H: H)
        if cfg.prop == .listening { drawListening(c, W: W, H: H, behind: true) }

        let body = bodyPath(W: W, H: H)
        c.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: color((255, 255, 255), 0.32), location: 0),
                             .init(color: color(), location: 0.55),
                             .init(color: color((0, 0, 0), 0.14), location: 1)]),
            startPoint: CGPoint(x: 0, y: -H), endPoint: .zero))

        var face = c
        face.clip(to: body)
        var shine = face
        shine.translateBy(x: -W * 0.42, y: -H * 0.72)
        shine.rotate(by: .radians(-0.5))
        shine.fill(ellipse(0, 0, W * 0.22, H * 0.12), with: .color(.white.opacity(0.28)))

        let fx = p.yaw * W * 0.3, fy = p.pitch * H * 0.09
        if p.blush > 0.01 {
            for side in [-1.0, 1.0] {
                face.fill(ellipse(side * W * 0.58 + fx * 0.8, -H * 0.36 + fy, W * 0.15, W * 0.08),
                          with: .color(Color(red: 1, green: 0.5, blue: 0.63, opacity: 0.7 * p.blush)))
            }
        }
        for side in [-1.0, 1.0] {
            let far = max(0, -side * p.yaw)                            // the far eye foreshortens
            var e = face
            e.translateBy(x: side * W * 0.36 * (1 - far * 0.15) + fx, y: -H * 0.5 + fy)
            e.scaleBy(x: 1 - far * 0.28, y: 1)
            drawEye(e, shape: engine.eye, side: side, ew: W * 0.115 * p.es, eh: W * 0.16 * p.es, W: W)
        }
        var m = face
        m.translateBy(x: fx * 1.05, y: -H * 0.31 + fy * 0.8)
        drawMouth(m, shape: engine.mouth, W: W)

        c.stroke(body, with: .color(.black.opacity(0.08)), lineWidth: W * 0.02)
        if cfg.prop == .listening { drawListening(c, W: W, H: H, behind: false) }
        if cfg.prop == .writing { drawWriting(c, W: W, H: H) }

        drawBadge(base, x: cx + p.ox * R + W * 0.92 * sx, y: gy + p.oy * R - H * 0.92 * sy, r: R * 0.3)
        if particles { drawParticles(base, cx: cx, gy: gy, R: R) }
    }

    // MARK: Shapes

    private func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    }

    private func bodyPath(W: Double, H: Double) -> Path {
        var b = Path()
        b.move(to: CGPoint(x: -W, y: -0.26 * H))
        b.addCurve(to: CGPoint(x: 0, y: -H), control1: CGPoint(x: -W, y: -0.72 * H), control2: CGPoint(x: -0.6 * W, y: -H))
        b.addCurve(to: CGPoint(x: W, y: -0.26 * H), control1: CGPoint(x: 0.6 * W, y: -H), control2: CGPoint(x: W, y: -0.72 * H))
        b.addCurve(to: .zero, control1: CGPoint(x: W, y: -0.03 * H), control2: CGPoint(x: 0.78 * W, y: 0))
        b.addCurve(to: CGPoint(x: -W, y: -0.26 * H), control1: CGPoint(x: -0.78 * W, y: 0), control2: CGPoint(x: -W, y: -0.03 * H))
        b.closeSubpath()
        return b
    }

    private func heartPath(_ s: Double) -> Path {
        var h = Path()
        h.move(to: CGPoint(x: 0, y: s * 0.38))
        h.addCurve(to: CGPoint(x: 0, y: -s * 0.45), control1: CGPoint(x: -s * 1.15, y: -s * 0.35), control2: CGPoint(x: -s * 0.48, y: -s * 1.08))
        h.addCurve(to: CGPoint(x: 0, y: s * 0.38), control1: CGPoint(x: s * 0.48, y: -s * 1.08), control2: CGPoint(x: s * 1.15, y: -s * 0.35))
        return h
    }

    private func line(_ points: [(Double, Double)]) -> Path {
        var l = Path()
        for (i, pt) in points.enumerated() {
            i == 0 ? l.move(to: CGPoint(x: pt.0, y: pt.1)) : l.addLine(to: CGPoint(x: pt.0, y: pt.1))
        }
        return l
    }

    private func quad(_ from: (Double, Double), _ control: (Double, Double), _ to: (Double, Double)) -> Path {
        var q = Path()
        q.move(to: CGPoint(x: from.0, y: from.1))
        q.addQuadCurve(to: CGPoint(x: to.0, y: to.1), control: CGPoint(x: control.0, y: control.1))
        return q
    }

    private func stroke(_ c: GraphicsContext, _ path: Path, _ color: Color, _ width: Double) {
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    // MARK: Parts

    private func drawSprout(_ base: GraphicsContext, W: Double, H: Double) {
        var a = p.leaf + sin(t * 1.8) * 0.06
        if cfg.wiggle { a += sin(t * 11) * 0.12 }
        var c = base
        c.translateBy(x: 0, y: -H * 0.95)
        c.rotate(by: .radians(a))
        stroke(c, quad((0, W * 0.1), (W * 0.07, -W * 0.22), (0, -W * 0.42)), Self.stem, W * 0.06)
        c.translateBy(x: 0, y: -W * 0.42)
        var big = c
        big.rotate(by: .radians(-0.55 + p.leafSpin))
        var leaf = Path()
        leaf.move(to: .zero)
        leaf.addQuadCurve(to: CGPoint(x: W * 0.44, y: -W * 0.32), control: CGPoint(x: W * 0.36, y: -W * 0.02))
        leaf.addQuadCurve(to: .zero, control: CGPoint(x: W * 0.1, y: -W * 0.32))
        big.fill(leaf, with: .color(Self.bigLeaf))
        stroke(big, line([(W * 0.02, -W * 0.02), (W * 0.32, -W * 0.24)]), Color(red: 30 / 255, green: 80 / 255, blue: 45 / 255, opacity: 0.35), W * 0.02)
        var small = c
        small.rotate(by: .radians(0.7 - p.leafSpin * 0.5))
        var leaf2 = Path()
        leaf2.move(to: .zero)
        leaf2.addQuadCurve(to: CGPoint(x: -W * 0.28, y: -W * 0.22), control: CGPoint(x: -W * 0.24, y: -W * 0.02))
        leaf2.addQuadCurve(to: .zero, control: CGPoint(x: -W * 0.06, y: -W * 0.22))
        small.fill(leaf2, with: .color(Self.smallLeaf))
    }

    private func drawEye(_ c: GraphicsContext, shape: SprigEye, side: Double, ew: Double, eh: Double, W: Double) {
        var shape = shape
        if (shape == .oval || shape == .wide) && p.open < 0.3 { shape = .blinkline }
        let lw = W * 0.055
        switch shape {
        case .oval, .wide:
            let k = shape == .wide ? 1.22 : 1
            c.fill(ellipse(0, 0, ew * k, eh * k * max(0.08, p.open)), with: .color(Self.ink))
            if p.open > 0.6 {
                c.fill(ellipse(ew * 0.35, -eh * 0.4 * k, ew * 0.36 * k, ew * 0.36 * k), with: .color(.white))
            }
        case .blinkline:
            stroke(c, line([(-ew * 1.1, 0), (ew * 1.1, 0)]), Self.ink, lw)
        case .flat:
            stroke(c, line([(-ew * 1.1, -side * eh * 0.12), (ew * 1.1, side * eh * 0.12)]), Self.ink, lw)
        case .happy:
            stroke(c, quad((-ew * 1.15, eh * 0.25), (0, -eh * 1.2), (ew * 1.15, eh * 0.25)), Self.ink, lw)
        case .closed:
            stroke(c, quad((-ew * 1.15, -eh * 0.1), (0, eh * 0.8), (ew * 1.15, -eh * 0.1)), Self.ink, lw)
        case .spiral:
            let pts = (0...44).map { i -> (Double, Double) in
                let f = Double(i) / 44, a = f * .pi * 4 + t * 7 * side, r = f * ew * 1.3
                return (cos(a) * r, sin(a) * r)
            }
            stroke(c, line(pts), Self.ink, W * 0.035)
        case .heart:
            var h = c
            let pulse = 1 + sin(t * 10) * 0.08
            h.scaleBy(x: pulse, y: pulse)
            h.fill(heartPath(ew * 1.45), with: .color(Self.pink))
        }
    }

    private func drawMouth(_ c: GraphicsContext, shape: SprigMouth, W: Double) {
        let lw = W * 0.045
        switch shape {
        case .smile:
            stroke(c, quad((-W * 0.1, 0), (0, W * 0.09), (W * 0.1, 0)), Self.ink, lw)
        case .grin:
            var g = quad((-W * 0.14, -W * 0.01), (0, W * 0.22), (W * 0.14, -W * 0.01))
            g.closeSubpath()
            c.fill(g, with: .color(Self.ink))
            c.fill(ellipse(0, W * 0.075, W * 0.06, W * 0.03), with: .color(Color(red: 0xF0 / 255, green: 0x7C / 255, blue: 0x8F / 255)))
        case .flat:
            stroke(c, line([(-W * 0.07, W * 0.02), (W * 0.07, W * 0.02)]), Self.ink, lw)
        case .frown:
            stroke(c, quad((-W * 0.09, W * 0.06), (0, -W * 0.04), (W * 0.09, W * 0.06)), Self.ink, lw)
        case .o:
            // While listening the mouth opens and closes with the voice.
            let open = cfg.prop == .listening ? 0.55 + engine.level * 0.6 : 1
            c.fill(ellipse(0, W * 0.03, W * 0.05, W * 0.065 * open), with: .color(Self.ink))
        case .wavy:
            let pts = (0...16).map { i -> (Double, Double) in
                let f = Double(i) / 16
                return (-W * 0.12 + f * W * 0.24, sin(f * .pi * 3 + t * 8) * W * 0.025 + W * 0.02)
            }
            stroke(c, line(pts), Self.ink, lw)
        }
    }

    private func drawBadge(_ base: GraphicsContext, x: Double, y: Double, r: Double) {
        guard let badge = engine.badge, p.badgeS >= 0.02 else { return }
        var c = base
        c.translateBy(x: x, y: y)
        c.scaleBy(x: p.badgeS, y: p.badgeS)
        let disc = ellipse(0, 0, r, r)
        c.fill(disc, with: .color(Color(red: engine.stateConfig.color.red, green: engine.stateConfig.color.green,
                                        blue: engine.stateConfig.color.blue)))
        c.stroke(disc, with: .color(.white.opacity(0.9)), lineWidth: r * 0.16)
        switch badge {
        case .dots:
            for i in -1...1 {
                let lift = max(0, sin(t * 6 - Double(i) * 0.9)) * r * 0.22
                c.fill(ellipse(Double(i) * r * 0.42, -lift, r * 0.15, r * 0.15), with: .color(.white))
            }
        case .bang:
            stroke(c, line([(0, -r * 0.5), (0, r * 0.1)]), .white, r * 0.22)
            c.fill(ellipse(0, r * 0.45, r * 0.13, r * 0.13), with: .color(.white))
        case .q:
            var q = Path()
            q.addArc(center: CGPoint(x: 0, y: -r * 0.18), radius: r * 0.3, startAngle: .radians(.pi * 1.1),
                     endAngle: .radians(.pi * 0.35), clockwise: false)
            q.addQuadCurve(to: CGPoint(x: 0, y: r * 0.15), control: CGPoint(x: 0, y: -r * 0.02))
            stroke(c, q, .white, r * 0.2)
            c.fill(ellipse(0, r * 0.47, r * 0.12, r * 0.12), with: .color(.white))
        case .dot:
            c.fill(ellipse(0, 0, r * 0.3, r * 0.3), with: .color(.white))
        case .check:
            stroke(c, line([(-r * 0.4, 0), (-r * 0.08, r * 0.32), (r * 0.45, -r * 0.3)]), .white, r * 0.22)
        }
    }

    private func drawParticles(_ base: GraphicsContext, cx: Double, gy: Double, R: Double) {
        for part in engine.particles {
            var c = base
            c.opacity = max(0, 1 - part.age / part.life)
            c.translateBy(x: cx + part.x * R, y: gy + part.y * R)
            let s = part.size * R
            switch part.kind {
            case .spark:
                c.rotate(by: .radians(part.rot))
                let star = line((0..<8).map { i in
                    let r = i % 2 == 1 ? s * 0.35 : s, a = Double(i) * .pi / 4
                    return (cos(a) * r, sin(a) * r)
                })
                c.fill(star, with: .color(Color(red: 0xF5 / 255, green: 0xB8 / 255, blue: 0x3D / 255)))
            case .heart:
                c.fill(heartPath(s), with: .color(Self.pink))
            case .z:
                let grow = 0.7 + part.age / part.life * 0.6
                c.draw(Text("z").font(.system(size: max(4, s * grow * 1.6), weight: .semibold)).foregroundColor(Self.light),
                       at: .zero)
            case .sweat:
                let d = s * 0.7
                var drop = Path()
                drop.move(to: CGPoint(x: 0, y: -d))
                drop.addQuadCurve(to: CGPoint(x: 0, y: d * 0.6), control: CGPoint(x: d * 0.9, y: d * 0.2))
                drop.addQuadCurve(to: CGPoint(x: 0, y: -d), control: CGPoint(x: -d * 0.9, y: d * 0.2))
                c.fill(drop, with: .color(Color(red: 0x6F / 255, green: 0xB7 / 255, blue: 0xF2 / 255)))
            case .note:
                c.draw(Text("♪").font(.system(size: max(5, s * 2.2), weight: .bold)).foregroundColor(Self.light), at: .zero)
            }
        }
    }

    // MARK: Gestures (Saywell)

    /// Listening: a hand cupped behind the ear, sound arcs coming in with the voice.
    private func drawListening(_ c: GraphicsContext, W: Double, H: Double, behind: Bool) {
        let earX = W * 0.98, earY = -H * 0.6
        if behind {
            // Sound arcs, brightest on loud speech, travelling toward the ear.
            for i in 0..<3 {
                let phase = (t * 1.6 - Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let radius = W * (0.95 - phase * 0.55)
                let alpha = (0.25 + 0.75 * engine.level) * sin(phase * .pi)
                var arc = Path()
                arc.addArc(center: CGPoint(x: earX, y: earY), radius: radius, startAngle: .radians(-0.7),
                           endAngle: .radians(0.7), clockwise: false)
                stroke(c, arc, Self.light.opacity(max(0, alpha)), W * 0.07)
            }
            return
        }
        var hand = c
        hand.translateBy(x: earX - W * 0.05, y: earY + W * 0.05)
        hand.rotate(by: .radians(-0.5 + sin(t * 3) * 0.05))
        let palm = ellipse(0, 0, W * 0.2, W * 0.3)
        hand.fill(palm, with: .color(color((0, 0, 0), 0.08)))
        hand.stroke(palm, with: .color(.black.opacity(0.12)), lineWidth: W * 0.02)
    }

    /// Writing: a notepad held in front, a pencil scribbling lines that fill in.
    private func drawWriting(_ base: GraphicsContext, W: Double, H: Double) {
        var c = base
        c.translateBy(x: W * 0.55, y: -H * 0.12)
        c.rotate(by: .radians(-0.12))
        let padW = W * 1.05, padH = W * 0.8
        let pad = Path(roundedRect: CGRect(x: -padW / 2, y: -padH / 2, width: padW, height: padH), cornerRadius: W * 0.08)
        c.fill(pad, with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
        c.stroke(pad, with: .color(.black.opacity(0.15)), lineWidth: W * 0.02)
        c.fill(Path(CGRect(x: -padW / 2, y: -padH / 2, width: padW, height: W * 0.1)),
               with: .color(Color(red: 0.93, green: 0.36, blue: 0.36)))

        // Three lines written one after the other, then a fresh page.
        let cycle = (t / 3.6).truncatingRemainder(dividingBy: 1)
        let x0 = -padW * 0.38, lineW = padW * 0.76
        var tip = (x0, -padH * 0.12)
        for j in 0..<3 {
            let y = -padH * 0.12 + Double(j) * padH * 0.22
            let fill = min(1, max(0, cycle * 3.3 - Double(j)))
            guard fill > 0 else { continue }
            let n = max(2, Int(fill * 14))
            let pts = (0...n).map { i -> (Double, Double) in
                let f = Double(i) / 14
                return (x0 + f * lineW, y + sin(f * 38 + Double(j)) * W * 0.03)
            }
            stroke(c, line(pts), Color(red: 0.25, green: 0.33, blue: 0.55), W * 0.035)
            if fill < 1 || j == 2 { tip = (x0 + fill * lineW, y) }
        }
        // Pencil, held by a little hand, its point on the line being written.
        var pencil = c
        pencil.translateBy(x: tip.0, y: tip.1 + sin(t * 30) * W * 0.02)
        pencil.rotate(by: .radians(-1.0))
        let len = W * 0.95, wid = W * 0.13
        pencil.fill(Path(CGRect(x: 0, y: -wid / 2, width: len, height: wid)),
                    with: .color(Color(red: 0.98, green: 0.78, blue: 0.25)))
        pencil.fill(Path(CGRect(x: len, y: -wid / 2, width: W * 0.14, height: wid)),
                    with: .color(Color(red: 0.95, green: 0.55, blue: 0.62)))
        var point = Path()
        point.move(to: CGPoint(x: 0, y: -wid / 2))
        point.addLine(to: CGPoint(x: -W * 0.16, y: 0))
        point.addLine(to: CGPoint(x: 0, y: wid / 2))
        point.closeSubpath()
        pencil.fill(point, with: .color(Color(red: 0.93, green: 0.8, blue: 0.62)))
        pencil.fill(ellipse(-W * 0.12, 0, W * 0.03, W * 0.03), with: .color(Self.ink))
        let hand = ellipse(len * 0.38, 0, W * 0.17, W * 0.14)
        pencil.fill(hand, with: .color(color((0, 0, 0), 0.08)))
        pencil.stroke(hand, with: .color(.black.opacity(0.12)), lineWidth: W * 0.02)
    }
}

private extension UInt32 {
    var red: Double { Double((self >> 16) & 255) / 255 }
    var green: Double { Double((self >> 8) & 255) / 255 }
    var blue: Double { Double(self & 255) / 255 }
}
