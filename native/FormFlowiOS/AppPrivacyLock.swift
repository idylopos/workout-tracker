import Foundation
import LocalAuthentication
import Observation
import SwiftUI

@MainActor @Observable
final class AppPrivacyLock {
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    private static let preferenceKey = "FormFlow.requireDeviceAuthentication"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.preferenceKey)
        isEnabled = enabled
        isLocked = enabled
    }

    func enable() async {
        if await authenticate(reason: "Protect your Form / Flow training records") {
            isEnabled = true
            isLocked = false
            defaults.set(true, forKey: Self.preferenceKey)
        }
    }

    func disable() {
        guard !isLocked else { return }
        isEnabled = false
        defaults.removeObject(forKey: Self.preferenceKey)
    }

    func lock() { if isEnabled { isLocked = true } }

    func unlock() async {
        if await authenticate(reason: "Open your Form / Flow training records") { isLocked = false }
    }

    private func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = "Set up device authentication in iPhone Settings to use app lock."
            return false
        }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            errorMessage = accepted ? nil : "Your records are still locked."
            return accepted
        } catch {
            errorMessage = "Authentication did not finish. You can try again."
            return false
        }
    }
}

struct PrivacyLockView: View {
    let lock: AppPrivacyLock
    var body: some View {
        ContentUnavailableView {
            Label("Your training records are locked", systemImage: "lock")
        } description: {
            Text(lock.errorMessage ?? "Unlock with your iPhone's authentication. An active workout continues to save while the app is locked.")
        } actions: {
            Button("Unlock") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent).disabled(lock.isAuthenticating)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}
