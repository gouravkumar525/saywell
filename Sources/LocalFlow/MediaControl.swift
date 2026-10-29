import AppKit

/// B12: optionally pauses Music and Spotify while dictating, and resumes only
/// what it paused. Uses Apple Events (macOS asks once per player), so it only
/// talks to players that are already running.
final class MediaControl {
    private static let players = ["com.apple.Music", "com.spotify.client"]
    private var paused: [String] = []
    private let queue = DispatchQueue(label: "saywell.media")

    func pauseIfPlaying() {
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else { return }
        queue.async {
            var paused: [String] = []
            for id in running {
                let script = """
                    tell application id "\(id)"
                        if player state is playing then
                            pause
                            return "paused"
                        end if
                    end tell
                    return ""
                    """
                if Self.run(script) == "paused" { paused.append(id) }
            }
            if !paused.isEmpty { Log.write("media: paused \(paused.joined(separator: ", "))") }
            DispatchQueue.main.async { self.paused += paused }
        }
    }

    func resume() {
        let ids = paused
        paused = []
        guard !ids.isEmpty else { return }
        queue.async {
            for id in ids { _ = Self.run("tell application id \"\(id)\" to play") }
            Log.write("media: resumed \(ids.joined(separator: ", "))")
        }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.write("media: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.stringValue
    }
}

/// B12: optional, quiet start/stop sounds.
enum DictationSound {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}
