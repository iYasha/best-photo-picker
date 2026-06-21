import Sparkle

/// Thin wrapper over Sparkle's standard updater.
///
/// Sparkle is only started when the running bundle actually carries a feed
/// (`SUFeedURL` in Info.plist) — i.e. the packaged, signed `.app`. A bare build
/// with no feed key stays dormant so the updater never errors on a missing feed.
///
/// The release pipeline (`scripts/release.sh`) publishes a GitHub release with the
/// zipped app and regenerates `appcast.xml`; `SUFeedURL` points at that feed's raw
/// URL, so installed copies pick up new versions. Mirrors github-pr-bar's setup.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?

    /// True when an update feed is configured (packaged `.app`), so the
    /// "Check for Updates…" affordance is worth showing.
    var isAvailable: Bool { controller != nil }

    private init() {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        } else {
            controller = nil
        }
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
