import Foundation

/// Sprig, Saywell's companion: a character drawn entirely in code (C3).
/// Swift port of `sprig_character.md`, same architecture:
///   1. Pose – a handful of numbers fully describe the character right now.
///   2. Tweens – actions animate those numbers through (target, ms, easing) keyframes.
///   3. States – data (color, eyes, mouth, badge, behaviour flags, entrance move).
///   4. Renderer – SprigView draws the pose every frame. No images.
/// This file has no UI code, so the animation logic is unit-tested with a fake clock.
/// Saywell adds two gestures: `listening` (hand cupped to the ear, sound arcs
/// that follow the voice) and `writing` (scribbling on a notepad).
public enum SprigEase {
    public typealias Fn = (Double) -> Double
    public static let out: Fn = { 1 - pow(1 - $0, 3) }
    public static let inOut: Fn = { $0 < 0.5 ? 4 * $0 * $0 * $0 : 1 - pow(-2 * $0 + 2, 3) / 2 }
    public static let back: Fn = { t in let c1 = 1.7, c3 = c1 + 1; return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) }
    public static let easeIn: Fn = { $0 * $0 }
    public static let lin: Fn = { $0 }
}

public enum SprigEye: String { case oval, wide, flat, happy, closed, spiral, heart, blinkline }
public enum SprigMouth: String { case smile, grin, flat, frown, o, wavy }
public enum SprigBadge: String { case dots, bang, q, dot, check }
/// Saywell's gestures: what Sprig holds or does with its hands.
public enum SprigProp: String { case none, listening, writing }

public enum PoseKey: CaseIterable {
    case yaw, pitch, tilt, open, sx, sy, ox, oy, spin, leaf, leafSpin, blush, es, badgeS
}

public struct SprigPose: Equatable {
    public var yaw = 0.0, pitch = 0.0, tilt = 0.0, open = 1.0, sx = 1.0, sy = 1.0, ox = 0.0, oy = 0.0
    public var spin = 0.0, leaf = 0.0, leafSpin = 0.0, blush = 0.0, es = 1.0, badgeS = 0.0

    public subscript(key: PoseKey) -> Double {
        get {
            switch key {
            case .yaw: return yaw
            case .pitch: return pitch
            case .tilt: return tilt
            case .open: return open
            case .sx: return sx
            case .sy: return sy
            case .ox: return ox
            case .oy: return oy
            case .spin: return spin
            case .leaf: return leaf
            case .leafSpin: return leafSpin
            case .blush: return blush
            case .es: return es
            case .badgeS: return badgeS
            }
        }
        set {
            switch key {
            case .yaw: yaw = newValue
            case .pitch: pitch = newValue
            case .tilt: tilt = newValue
            case .open: open = newValue
            case .sx: sx = newValue
            case .sy: sy = newValue
            case .ox: ox = newValue
            case .oy: oy = newValue
            case .spin: spin = newValue
            case .leaf: leaf = newValue
            case .leafSpin: leafSpin = newValue
            case .blush: blush = newValue
            case .es: es = newValue
            case .badgeS: badgeS = newValue
            }
        }
    }
}

/// One keyframe: animate to `target` over `ms` with `ease`.
public struct SprigKey {
    public var target: Double
    public var ms: Double
    public var ease: SprigEase.Fn

    public init(_ target: Double, _ ms: Double, _ ease: @escaping SprigEase.Fn = SprigEase.lin) {
        self.target = target
        self.ms = ms
        self.ease = ease
    }
}

public struct SprigStateConfig {
    public var name: String
    public var label: String
    /// 0xRRGGBB
    public var color: UInt32
    public var eye: SprigEye
    public var mouth: SprigMouth
    public var badge: SprigBadge?
    public var look: (x: Double, y: Double)?
    public var leaf = 0.0
    public var tilt = 0.0
    public var blush = 0.0
    public var scans = false
    public var wiggle = false
    public var bounces = false
    public var sweat = false
    public var zz = false
    public var breathes = false
    public var prop: SprigProp = .none
    public var enter: ((SprigEngine) -> Void)?

    public init(_ name: String, _ label: String, color: UInt32, eye: SprigEye = .oval, mouth: SprigMouth = .smile,
                badge: SprigBadge? = nil, enter: ((SprigEngine) -> Void)? = nil) {
        self.name = name
        self.label = label
        self.color = color
        self.eye = eye
        self.mouth = mouth
        self.badge = badge
        self.enter = enter
    }
}

public struct SprigParticle {
    public enum Kind { case spark, heart, z, sweat, note }
    public var kind: Kind
    /// Position and velocity in body units (R) from the ground point under Sprig.
    public var x: Double, y: Double, vx: Double, vy: Double
    public var age = 0.0
    public var life: Double
    public var rot: Double
    public var size: Double
}

public final class SprigEngine {

    // MARK: States and actions (data)

    public static let defaultStates: [String: SprigStateConfig] = {
        var s: [String: SprigStateConfig] = [:]
        func add(_ c: SprigStateConfig) { s[c.name] = c }

        add(SprigStateConfig("idle", "Idle", color: 0x8CCF9A, enter: { $0.play("blink") }))

        var thinking = SprigStateConfig("thinking", "Thinking", color: 0x9B7BF0, mouth: .flat, badge: .dots,
                                        enter: { $0.play("blink") })
        thinking.look = (0.65, -0.7)
        thinking.leaf = -0.25
        add(thinking)

        var working = SprigStateConfig("working", "Working", color: 0x4F8DF7, mouth: .flat, badge: .dots,
                                       enter: { $0.play("blink") })
        working.scans = true
        working.wiggle = true
        add(working)

        var approval = SprigStateConfig("approval", "Waiting for approval", color: 0xF0A53A, eye: .wide, mouth: .o,
                                        badge: .bang, enter: {
            $0.anim(.oy, [SprigKey(-0.2, 150, SprigEase.out), SprigKey(0, 320, SprigEase.back)])
        })
        approval.bounces = true
        approval.leaf = 0.12
        add(approval)

        var question = SprigStateConfig("question", "Asking a question", color: 0x2BB3C8, mouth: .flat, badge: .q,
                                        enter: { $0.play("blink") })
        question.tilt = 0.17
        add(question)

        var error = SprigStateConfig("error", "Error", color: 0xEC5F5F, eye: .flat, mouth: .frown, badge: .dot,
                                     enter: { $0.play("shake") })
        error.leaf = 0.75
        error.sweat = true
        add(error)

        var done = SprigStateConfig("done", "Done", color: 0x36C08A, eye: .happy, mouth: .grin, badge: .check, enter: { e in
            e.play("jump")
            if !e.reducedMotion {
                e.anim(.leafSpin, [SprigKey(.pi * 2, 800, SprigEase.inOut)]) { e.pose.leafSpin = 0 }
            }
            e.later(420) { e.burst(.spark, count: e.reducedMotion ? 3 : 7) }
        })
        done.blush = 1
        add(done)

        var sleeping = SprigStateConfig("sleeping", "Sleeping", color: 0x8E9BB0, eye: .closed, mouth: .flat)
        sleeping.zz = true
        sleeping.breathes = true
        sleeping.leaf = 1.0
        add(sleeping)

        add(SprigStateConfig("dizzy", "Dizzy", color: 0xEE79B4, eye: .spiral, mouth: .wavy, enter: { e in
            if !e.reducedMotion { e.anim(.spin, [SprigKey(.pi * 4, 1300, SprigEase.inOut)]) { e.pose.spin = 0 } }
        }))

        // Saywell: dictation. A hand cupped to the ear; eyes and sound arcs follow the voice.
        var listening = SprigStateConfig("listening", "Listening", color: 0xFF8A4C, mouth: .o, enter: { e in
            e.play("squish")
            e.anim(.es, [SprigKey(1.2, 160, SprigEase.back), SprigKey(1, 260, SprigEase.inOut)])
        })
        listening.look = (0.55, -0.15)
        listening.tilt = -0.1
        listening.leaf = -0.15
        listening.prop = .listening
        add(listening)

        // Saywell: note-taking. Scribbles on a notepad, eyes on the page.
        var writing = SprigStateConfig("writing", "Taking notes", color: 0xF2B84B, mouth: .smile, enter: { $0.play("blink") })
        writing.look = (0.45, 0.75)
        writing.tilt = 0.06
        writing.leaf = 0.1
        writing.prop = .writing
        add(writing)

        return s
    }()

    public static let defaultActions: [String: (SprigEngine) -> Void] = [
        "blink": { e in
            guard !e.isAnimating(.open) else { return }
            e.anim(.open, [SprigKey(0.06, 70, SprigEase.inOut), SprigKey(1, 130, SprigEase.out)])
        },
        "squish": { e in
            e.anim(.sy, [SprigKey(0.78, 70, SprigEase.out), SprigKey(1.1, 130, SprigEase.out), SprigKey(1, 170, SprigEase.inOut)])
            e.anim(.sx, [SprigKey(1.16, 70, SprigEase.out), SprigKey(0.95, 130, SprigEase.out), SprigKey(1, 170, SprigEase.inOut)])
        },
        "jump": { e in
            // anticipation squash → rise → fall (ease-in) → landing squish
            e.anim(.sy, [SprigKey(0.8, 110, SprigEase.out), SprigKey(1.14, 160, SprigEase.out), SprigKey(1, 240, SprigEase.inOut)])
            e.anim(.sx, [SprigKey(1.15, 110, SprigEase.out), SprigKey(0.92, 160, SprigEase.out), SprigKey(1, 240, SprigEase.inOut)])
            e.anim(.oy, [SprigKey(0, 110), SprigKey(-0.95, 280, SprigEase.out), SprigKey(0, 260, SprigEase.easeIn)]) {
                e.play("squish")
            }
        },
        "shake": { e in
            e.anim(.ox, [SprigKey(0.09, 50, SprigEase.out), SprigKey(-0.09, 70, SprigEase.inOut), SprigKey(0.06, 70, SprigEase.inOut),
                         SprigKey(-0.03, 70, SprigEase.inOut), SprigKey(0, 90, SprigEase.out)])
        },
        "spin": { e in
            if e.reducedMotion { e.play("squish"); return }
            e.anim(.sy, [SprigKey(0.86, 90, SprigEase.out), SprigKey(1, 200, SprigEase.out)])
            e.anim(.spin, [SprigKey(.pi * 2, 750, SprigEase.inOut)]) { e.pose.spin = 0 }
        },
        "hearts": { e in
            e.setEyes(.heart, ms: 1600)
            e.setMouth(.grin, ms: 1600)
            let rest = e.stateConfig.blush
            e.anim(.blush, [SprigKey(1, 200, SprigEase.out), SprigKey(1, 1200), SprigKey(rest, 400, SprigEase.out)])
            e.burst(.heart, count: e.reducedMotion ? 2 : 5)
            e.play("squish")
        },
        "lookAround": { e in
            e.lookOverride = (-1, -0.1)
            e.later(600) { e.lookOverride = (1, -0.1) }
            e.later(1200) { e.lookOverride = (0, 0.5) }
            e.later(1700) { e.lookOverride = nil; e.play("blink") }
        },
        "bigEyes": { e in
            e.anim(.es, [SprigKey(1.45, 180, SprigEase.back), SprigKey(1.45, 700), SprigKey(1, 300, SprigEase.inOut)])
            e.setMouth(.o, ms: 1100)
        },
    ]

    // MARK: Options

    public var reducedMotion: Bool
    /// Seconds idle before falling asleep (0 = never).
    public var sleepAfter: Double
    public var dizzyClicks = 3
    public var dizzyMs = 2600.0

    // MARK: State

    public private(set) var pose = SprigPose()
    public private(set) var state: String
    public private(set) var stateConfig: SprigStateConfig
    /// Current body color (r, g, b in 0...255), easing toward the state's color.
    public private(set) var color: (r: Double, g: Double, b: Double)
    public private(set) var badge: SprigBadge?
    public private(set) var particles: [SprigParticle] = []
    /// Seconds since the engine started; drives idle motion.
    public private(set) var time = 0.0
    /// Pointer direction (-1...1, -1...1, y down), set by the view every frame.
    public var pointer: (x: Double, y: Double) = (0, 0)
    /// Eyes forced to a direction by an action, or nil.
    public var lookOverride: (x: Double, y: Double)?
    /// Voice level 0...1 while listening, smoothed.
    public private(set) var level = 0.0
    public var targetLevel = 0.0

    private var states: [String: SprigStateConfig]
    private var actions: [String: (SprigEngine) -> Void]
    private struct Tween { var keys: [SprigKey]; var i: Int; var from: Double; var start: Double; var done: (() -> Void)? }
    private var tweens: [PoseKey: Tween] = [:]
    private var timers: [(at: Double, id: Int, fn: () -> Void)] = []
    private var timerID = 0
    private var eyeOverride: (SprigEye, until: Double)?
    private var mouthOverride: (SprigMouth, until: Double)?
    private var badgeToken = 0
    private var pokes: [Double] = []
    private var dizzyToken = 0
    private var stateSince = 0.0
    private var nextBlink = 2.5, nextBounce = 0.0, nextZ = 0.0, nextSweat = 0.0, nextNote = 0.0
    private var started: Double?
    private var last = 0.0
    private let random: () -> Double

    public init(state: String = "idle", reducedMotion: Bool = false, sleepAfter: Double = 0,
                random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        states = Self.defaultStates
        actions = Self.defaultActions
        let cfg = states[state] ?? states["idle"]!
        self.state = cfg.name
        stateConfig = cfg
        color = Self.rgb(cfg.color)
        self.reducedMotion = reducedMotion
        self.sleepAfter = sleepAfter
        self.random = random
        badge = cfg.badge
        pose.badgeS = cfg.badge == nil ? 0 : 1
        pose.blush = cfg.blush
    }

    public var stateNames: [String] { states.keys.sorted() }
    public var actionNames: [String] { actions.keys.sorted() }

    public func isAnimating(_ key: PoseKey) -> Bool { tweens[key] != nil }

    public var eye: SprigEye {
        if let o = eyeOverride, time < o.until { return o.0 }
        return stateConfig.eye
    }

    public var mouth: SprigMouth {
        if let o = mouthOverride, time < o.until { return o.0 }
        return stateConfig.mouth
    }

    // MARK: Tweens and timers

    public func anim(_ key: PoseKey, _ keys: [SprigKey], done: (() -> Void)? = nil) {
        guard !keys.isEmpty else { return }
        tweens[key] = Tween(keys: keys, i: 0, from: pose[key], start: time, done: done)
    }

    @discardableResult
    public func later(_ ms: Double, _ fn: @escaping () -> Void) -> Int {
        timerID += 1
        timers.append((time + ms / 1000, timerID, fn))
        return timerID
    }

    public func setEyes(_ eye: SprigEye, ms: Double) { eyeOverride = (eye, time + ms / 1000) }
    public func setMouth(_ mouth: SprigMouth, ms: Double) { mouthOverride = (mouth, time + ms / 1000) }

    private func stepTweens() {
        for key in Array(tweens.keys) {
            guard var tw = tweens[key] else { continue }
            let kf = tw.keys[tw.i]
            let p = min(1, max(0, (time - tw.start) * 1000 / max(1, kf.ms)))
            pose[key] = tw.from + (kf.target - tw.from) * kf.ease(p)
            if p >= 1 {
                tw.from = kf.target
                tw.i += 1
                tw.start = time
                if tw.i >= tw.keys.count {
                    tweens[key] = nil
                    tw.done?()
                    continue
                }
            }
            tweens[key] = tw
        }
    }

    private func runTimers() {
        let due = timers.filter { $0.at <= time }
        guard !due.isEmpty else { return }
        timers.removeAll { $0.at <= time }
        due.sorted { $0.id < $1.id }.forEach { $0.fn() }
    }

    // MARK: State and actions

    private func setBadge(_ b: SprigBadge?) {
        guard b != badge else { return }
        badgeToken += 1
        let token = badgeToken
        anim(.badgeS, [SprigKey(0, 90, SprigEase.inOut)]) { [weak self] in
            guard let self, token == self.badgeToken else { return }
            self.badge = b
            if b != nil { self.anim(.badgeS, [SprigKey(1, 280, SprigEase.back)]) }
        }
    }

    @discardableResult
    public func setState(_ name: String, force: Bool = false) -> Bool {
        guard let cfg = states[name] else { return false }
        if name == state && !force { return false }
        state = name
        stateConfig = cfg
        stateSince = time
        if name != "dizzy" { dizzyToken += 1 }   // an explicit change cancels the return from dizzy
        setBadge(cfg.badge)
        anim(.blush, [SprigKey(cfg.blush, 300, SprigEase.out)])
        cfg.enter?(self)
        return true
    }

    @discardableResult
    public func play(_ name: String) -> Bool {
        guard let fn = actions[name] else { return false }
        fn(self)
        return true
    }

    /// A click on Sprig: squish; three quick ones make it dizzy for a moment.
    public func poke() {
        guard state != "dizzy" else { return }
        pokes = pokes.filter { time - $0 < 1.5 } + [time]
        play("squish")
        if pokes.count >= dizzyClicks {
            pokes = []
            let back = state
            setState("dizzy")
            dizzyToken += 1
            let token = dizzyToken
            later(dizzyMs) { [weak self] in
                guard let self, token == self.dizzyToken, self.state == "dizzy" else { return }
                self.setState(back)
            }
        } else {
            setEyes(.flat, ms: 700)
            setMouth(.frown, ms: 700)
        }
    }

    // MARK: Particles

    public func burst(_ kind: SprigParticle.Kind, count: Int = 1) {
        let height = 1.9
        for _ in 0..<count {
            let top = pose.oy - height * 1.02
            let spread = kind == .z ? 0.4 : 1.4
            var p = SprigParticle(kind: kind,
                                  x: (random() - 0.5) * spread + (kind == .z ? 0.5 : 0),
                                  y: top + (kind == .sweat ? height * 0.25 : 0),
                                  vx: (random() - 0.5) * (kind == .spark ? 6.5 : 1.25) + (kind == .z ? 0.5 : 0),
                                  vy: kind == .spark ? -5 - random() * 4 : (kind == .sweat ? 1 : -1.25 - random()),
                                  life: kind == .z ? 2.4 : 1.4 + random() * 0.5,
                                  rot: random() * .pi,
                                  size: (kind == .z ? 0.22 : 0.13) * (0.8 + random() * 0.4))
            if kind == .note {
                // Little notes drift away from the cupped ear.
                p.x = 1.55
                p.y = -height * 0.62
                p.vx = 0.9 + random() * 0.4
                p.vy = -0.7 - random() * 0.4
                p.life = 1.1
                p.size = 0.2
            }
            particles.append(p)
        }
    }

    private func stepParticles(_ dt: Double) {
        particles = particles.filter { $0.age < $0.life }
        for i in particles.indices {
            var p = particles[i]
            p.age += dt
            p.x += p.vx * dt
            p.y += p.vy * dt
            switch p.kind {
            case .spark:
                p.vy += 13 * dt
                p.rot += dt * 6
            case .sweat:
                p.vy += 7.5 * dt
            case .z:
                p.vx = 0.55 + sin(p.age * 3) * 0.6
            case .heart, .note:
                break
            }
            particles[i] = p
        }
    }

    // MARK: Frame

    /// Advances to `now` (seconds, any monotonic clock).
    public func update(now: Double) {
        if started == nil { started = now; last = now }
        let dt = min(0.05, max(0, now - last))
        last = now
        time = now - (started ?? now)
        let cfg = stateConfig

        runTimers()
        stepTweens()

        var tx = pointer.x, ty = pointer.y
        if let o = lookOverride {
            (tx, ty) = o
        } else if let look = cfg.look {
            tx = tx * 0.3 + look.x * 0.7
            ty = ty * 0.3 + look.y * 0.7
        } else if cfg.scans {
            tx = sin(time * 2.8) * 0.7
            ty = 0.35
        }
        if state == "sleeping" { tx = 0; ty = 0.25 }
        if state == "dizzy" { tx = sin(time * 9) * 0.5; ty = 0 }
        if cfg.prop == .writing { tx += sin(time * 4.5) * 0.12 }   // follows the pencil
        let k = 1 - exp(-dt * 10)
        pose.yaw += (tx - pose.yaw) * k
        pose.pitch += (ty - pose.pitch) * k
        let k2 = 1 - exp(-dt * 6)
        pose.tilt += (cfg.tilt - pose.tilt) * k2
        pose.leaf += (cfg.leaf - pose.leaf) * k2
        let target = Self.rgb(cfg.color)
        let kc = 1 - exp(-dt * 7)
        color = (color.r + (target.r - color.r) * kc, color.g + (target.g - color.g) * kc, color.b + (target.b - color.b) * kc)

        // Voice: fast attack, slower release; eyes widen a little with loud speech.
        let rate = targetLevel > level ? 18.0 : 6.0
        level += (targetLevel - level) * (1 - exp(-dt * rate))
        if cfg.prop == .listening, !isAnimating(.es) { pose.es = 1 + level * 0.18 }

        if time > nextBlink {
            if eye == .oval || eye == .wide { play("blink") }
            nextBlink = time + 2.2 + random() * 3.2
        }
        if cfg.bounces, time > nextBounce, !isAnimating(.oy) {
            anim(.oy, [SprigKey(-0.14, 160, SprigEase.out), SprigKey(0, 300, SprigEase.back)])
            nextBounce = time + 1.5
        }
        if cfg.zz, time > nextZ { burst(.z); nextZ = time + 1 }
        if cfg.sweat, time > nextSweat { burst(.sweat); nextSweat = time + 1.8 }
        if cfg.prop == .listening, level > 0.25, time > nextNote, !reducedMotion { burst(.note); nextNote = time + 0.7 }
        if sleepAfter > 0, state == "idle", time - stateSince > sleepAfter, states["sleeping"] != nil { setState("sleeping") }

        stepParticles(dt)
    }

    static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255))
    }
}
