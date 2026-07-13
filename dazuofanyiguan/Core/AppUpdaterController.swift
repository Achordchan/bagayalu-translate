import Sparkle
import SwiftUI

@MainActor
final class AppUpdaterController: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()

        guard !Self.isRunningTests else {
            return
        }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        let updater = updaterController.updater
        canCheckObservation = updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            let canCheck = change.newValue ?? false
            Task { @MainActor in
                self?.canCheckForUpdates = canCheck
            }
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }
}
