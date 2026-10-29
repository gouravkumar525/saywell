import Foundation
import Sparkle

/// B13: in-app updates with Sparkle 2 (EdDSA-signed appcast). Off unless the
/// build's Info.plist has `SUFeedURL` and `SUPublicEDKey` (see INSTALL.md,
/// "Publishing updates"), so self-signed builds never phone home.
final class Updater {
    private var controller: SPUStandardUpdaterController?

    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return !((info["SUFeedURL"] as? String) ?? "").isEmpty && !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
    }

    init() {
        guard Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        Log.write("updates: Sparkle on (\(Bundle.main.infoDictionary?["SUFeedURL"] ?? ""))")
    }

    var isEnabled: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
