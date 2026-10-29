import AppKit
import Darwin
import Foundation

/// Ordinary lowercase English words, from the system word list. Used to keep
/// vocabulary correction off common words and to decide mid-sentence casing.
final class CommonWords {
    static let shared = CommonWords()
    private var words: Set<String>?
    private let lock = NSLock()

    /// Loads in the background (~235K words, a few MB).
    func preload() {
        DispatchQueue.global(qos: .utility).async { self.loadNow() }
    }

    func loadNow() {
        let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
        // Capitalized entries are proper names; only lowercase ones are "common".
        let set = Set(text.split(separator: "\n").filter { $0.first?.isLowercase == true }.map(String.init))
        lock.lock()
        words = set
        lock.unlock()
    }

    /// nil until loaded.
    func contains(_ word: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return words.map { $0.contains(word) }
    }

    /// Protects words from vocabulary correction (everything is protected until loaded).
    func isProtected(_ word: String) -> Bool { contains(word) ?? true }

    /// May be lowercased mid-sentence (nothing is until loaded).
    func isLowercasable(_ word: String) -> Bool { contains(word) ?? false }
}

/// This process's memory as Activity Monitor reports it ("Memory" column).
enum MemoryInfo {
    struct Footprint {
        let current: UInt64
        let peak: UInt64
    }

    static func footprint() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Footprint(current: 0, peak: 0) }
        return Footprint(current: info.phys_footprint, peak: UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    static func format(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// Where keyboard focus is right now, to detect focus moving during a dictation.
enum FocusCheck {
    static func moved(from ctx: FocusContext) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        if let pid = ctx.pid, front?.processIdentifier != pid { return true }
        // Electron rebuilds its AX elements freely, so only the app is compared there.
        guard let original = ctx.element, !ctx.isElectron, AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let now: AXUIElement = ContextProvider.attribute(system, kAXFocusedUIElementAttribute) else { return false }
        return !CFEqual(now, original)
    }
}
