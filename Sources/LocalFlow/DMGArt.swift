import AppKit
import LocalFlowCore
import SwiftUI

/// The installer window's background (Scripts/package.sh): drag Saywell onto
/// Applications, with Sprig cheering and the one-time "Open Anyway" hint for
/// Macs that warn about apps from outside the App Store.
/// `Saywell --dmg-background <prefix>` writes <prefix>.png and <prefix>@2x.png.
enum DMGArt {
    static let size = CGSize(width: 660, height: 440)
    /// Icon centres in the window (dmgbuild uses the same numbers).
    static let appCenter = CGPoint(x: 170, y: 200)
    static let applicationsCenter = CGPoint(x: 490, y: 200)

    @MainActor
    static func write(prefix: String) -> Bool {
        let sprig = SprigEngine(state: "idle", reducedMotion: true, random: { 0.5 })
        sprig.update(now: 0)
        sprig.setState("done")
        var t = 0.0
        for _ in 0..<70 { t += 1.0 / 60; sprig.update(now: t) }   // mid-way through the happy hop, sparks out
        let view = Background(sprig: sprig).frame(width: size.width, height: size.height)
        for (scale, suffix) in [(1.0, ""), (2.0, "@2x")] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: URL(fileURLWithPath: prefix + suffix + ".png")) } catch { return false }
        }
        return true
    }

    private struct Background: View {
        let sprig: SprigEngine
        private let ink = Color(red: 0.16, green: 0.12, blue: 0.10)
        private let accent = Color(red: 0.93, green: 0.52, blue: 0.20)

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 1.0, green: 0.97, blue: 0.93), Color(red: 0.99, green: 0.90, blue: 0.80)],
                               startPoint: .top, endPoint: .bottom)
                // Soft glow behind the icons.
                Ellipse().fill(accent.opacity(0.10)).frame(width: 520, height: 210).offset(x: 70, y: 100)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saywell").font(.system(size: 26, weight: .bold)).foregroundColor(ink)
                    Text("Private voice typing and call notes for your Mac")
                        .font(.system(size: 13)).foregroundColor(ink.opacity(0.6))
                }
                .offset(x: 34, y: 28)
                arrow.offset(x: 0, y: 0)
                Canvas { context, size in
                    SprigRenderer(engine: sprig, size: size, scale: 0.26, ground: 0.95, particles: true).draw(in: context)
                }
                .frame(width: 84, height: 84)
                .offset(x: (DMGArt.appCenter.x + DMGArt.applicationsCenter.x) / 2 - 42, y: DMGArt.appCenter.y - 128)
                VStack(alignment: .center, spacing: 8) {
                    Text("Drag Saywell to Applications, then open it from there.")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
                    Text("First time only: if macOS says it can't verify Saywell, open System Settings ▸ Privacy & Security, scroll down and click Open Anyway.")
                        .font(.system(size: 11)).foregroundColor(ink.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .frame(width: 520)
                }
                .frame(width: DMGArt.size.width)
                .offset(y: 330)
            }
            .frame(width: DMGArt.size.width, height: DMGArt.size.height, alignment: .topLeading)
        }

        /// A friendly curved arrow from the app to Applications.
        private var arrow: some View {
            Canvas { context, _ in
                let from = CGPoint(x: DMGArt.appCenter.x + 78, y: DMGArt.appCenter.y)
                let to = CGPoint(x: DMGArt.applicationsCenter.x - 82, y: DMGArt.applicationsCenter.y)
                var path = Path()
                path.move(to: from)
                path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: from.y - 34))
                context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 9]))
                var head = Path()
                head.move(to: CGPoint(x: to.x - 14, y: to.y - 11))
                head.addLine(to: to)
                head.addLine(to: CGPoint(x: to.x - 15, y: to.y + 9))
                context.stroke(head, with: .color(accent), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            .frame(width: DMGArt.size.width, height: DMGArt.size.height)
        }
    }
}
