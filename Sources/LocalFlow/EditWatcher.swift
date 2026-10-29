import ApplicationServices
import Foundation
import LocalFlowCore

/// For ~10s after an insertion, re-reads the field over AX and diffs our text
/// against what's there now. Small word substitutions are recorded as
/// correction candidates; repeated ones get promoted into the dictionary.
/// The final text of the region is also saved on the training sample.
final class EditWatcher {
    private var timer: Timer?
    private var deadline = Date()
    private var element: AXUIElement?
    private var inserted = ""
    private var prefix = ""
    private var suffix = ""
    private var lastRegion: String?
    private var sampleID: Int64?
    /// Set when the anchors around the region changed or the field went away.
    private var lost = false
    private let store: Store?
    var onLearned: ((String) -> Void)?

    init(store: Store?) { self.store = store }

    func watch(element: AXUIElement, location: Int, inserted: String, sampleID: Int64? = nil,
               duration: TimeInterval = 10) {
        stop()
        guard let value: String = ContextProvider.attribute(element, kAXValueAttribute) else { return }
        let ns = value as NSString
        let length = (inserted as NSString).length
        // Only follow along if the text really is where we think it is.
        guard location + length <= ns.length,
              ns.substring(with: NSRange(location: location, length: length)) == inserted,
              ns.length < 200_000 else { return }

        self.element = element
        self.inserted = inserted
        self.sampleID = sampleID
        lost = false
        prefix = ns.substring(to: location)
        suffix = ns.substring(from: location + length)
        lastRegion = inserted
        deadline = Date().addingTimeInterval(duration)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Ends the watch and learns from the final state of the field.
    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let region = lastRegion, region != inserted {
            learn(from: region)
        }
        if let sampleID {
            if !lost, let region = lastRegion {
                store?.updateSampleFinal(id: sampleID, finalText: region)
                Log.write("training: sample \(sampleID) final \(region == inserted ? "unchanged" : "edited")")
            } else {
                Log.write("training: sample \(sampleID) lost track; final_text left empty")
            }
        }
        element = nil
        lastRegion = nil
        sampleID = nil
    }

    private func poll() {
        guard let element, Date() < deadline else {
            stop()
            return
        }
        guard let value: String = ContextProvider.attribute(element, kAXValueAttribute) else {
            lost = true
            stop()
            return
        }
        // The inserted region is whatever sits between the untouched text
        // before and after it. If either side changed, we've lost track.
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count else {
            lost = true
            stop()
            return
        }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        lastRegion = String(value[start..<end])
    }

    private func learn(from region: String) {
        let corrections = EditDiff.corrections(inserted: inserted, edited: region)
        for c in corrections {
            Log.write("edit-watcher: \"\(c.original)\" → \"\(c.corrected)\"")
            if store?.recordCorrection(original: c.original, corrected: c.corrected,
                                     isCommonWord: CommonWords.shared.isProtected) == true {
                Log.write("edit-watcher: learned \"\(c.corrected)\"")
                onLearned?(c.corrected)
            }
        }
    }
}
