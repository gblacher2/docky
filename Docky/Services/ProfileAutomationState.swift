//
//  ProfileAutomationState.swift
//  Docky
//

import Foundation
import Observation

@MainActor
@Observable
final class ProfileAutomationState {
    static let shared = ProfileAutomationState()

    enum PauseChoice: String, CaseIterable, Identifiable {
        case thirtyMinutes
        case oneHour
        case untilTomorrow
        case indefinitely

        var id: String { rawValue }
    }

    private(set) var pauseExpiry: Date?
    private(set) var isPausedIndefinitely: Bool
    private(set) var isFocusLocked: Bool
    private(set) var focusLockStartDate: Date?
    private(set) var previousProfileID: String?
    private(set) var activeTriggerID: String?
    private(set) var lastTransitionReason: String
    private(set) var lastWarning: String?

    var isPaused: Bool {
        if isPausedIndefinitely { return true }
        return pauseExpiry.map { $0 > Date() } ?? false
    }

    var pauseDescription: String? {
        if isPausedIndefinitely { return String(localized: "Paused indefinitely") }
        guard let pauseExpiry, pauseExpiry > Date() else { return nil }
        return String(localized: "Paused until \(pauseExpiry.formatted(date: .omitted, time: .shortened))")
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let pauseExpiry = "docky.profileAutomation.pauseExpiry"
        static let isPausedIndefinitely = "docky.profileAutomation.pausedIndefinitely"
        static let isFocusLocked = "docky.profileAutomation.focusLocked"
        static let focusLockStartDate = "docky.profileAutomation.focusLockStartDate"
        static let previousProfileID = "docky.profileAutomation.previousProfileID"
        static let activeTriggerID = "docky.profileAutomation.activeTriggerID"
        static let lastTransitionReason = "docky.profileAutomation.lastTransitionReason"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pauseExpiry = defaults.object(forKey: Keys.pauseExpiry) as? Date
        isPausedIndefinitely = defaults.bool(forKey: Keys.isPausedIndefinitely)
        isFocusLocked = defaults.bool(forKey: Keys.isFocusLocked)
        focusLockStartDate = defaults.object(forKey: Keys.focusLockStartDate) as? Date
        previousProfileID = defaults.string(forKey: Keys.previousProfileID)
        activeTriggerID = defaults.string(forKey: Keys.activeTriggerID)
        lastTransitionReason = defaults.string(forKey: Keys.lastTransitionReason) ?? String(localized: "Not evaluated yet")
        lastWarning = nil
        clearExpiredPauseIfNeeded()
    }

    func pause(_ choice: PauseChoice, now: Date = Date(), calendar: Calendar = .current) {
        isPausedIndefinitely = choice == .indefinitely
        switch choice {
        case .thirtyMinutes:
            pauseExpiry = now.addingTimeInterval(30 * 60)
        case .oneHour:
            pauseExpiry = now.addingTimeInterval(60 * 60)
        case .untilTomorrow:
            pauseExpiry = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .indefinitely:
            pauseExpiry = nil
        }
        activeTriggerID = nil
        lastTransitionReason = String(localized: "Automation paused")
        persist()
    }

    func resume() {
        pauseExpiry = nil
        isPausedIndefinitely = false
        lastTransitionReason = String(localized: "Automation resumed")
        persist()
    }

    @discardableResult
    func clearExpiredPauseIfNeeded(now: Date = Date()) -> Bool {
        guard !isPausedIndefinitely, let pauseExpiry, pauseExpiry <= now else { return false }
        self.pauseExpiry = nil
        lastTransitionReason = String(localized: "Automation pause expired")
        persist()
        return true
    }

    func beginFocusLock(previousProfileID: String) {
        isFocusLocked = true
        focusLockStartDate = Date()
        self.previousProfileID = previousProfileID
        activeTriggerID = "focusflow"
        lastTransitionReason = String(localized: "CFA Focus started")
        lastWarning = nil
        persist()
    }

    @discardableResult
    func endFocusLock() -> String? {
        let previous = previousProfileID
        isFocusLocked = false
        focusLockStartDate = nil
        previousProfileID = nil
        activeTriggerID = nil
        lastTransitionReason = String(localized: "CFA Focus ended")
        persist()
        return previous
    }

    func recordTransition(triggerID: String?, reason: String) {
        activeTriggerID = triggerID
        lastTransitionReason = reason
        persist()
    }

    func recordWarning(_ warning: String?) {
        lastWarning = warning
    }

    private func persist() {
        defaults.set(pauseExpiry, forKey: Keys.pauseExpiry)
        defaults.set(isPausedIndefinitely, forKey: Keys.isPausedIndefinitely)
        defaults.set(isFocusLocked, forKey: Keys.isFocusLocked)
        defaults.set(focusLockStartDate, forKey: Keys.focusLockStartDate)
        defaults.set(previousProfileID, forKey: Keys.previousProfileID)
        defaults.set(activeTriggerID, forKey: Keys.activeTriggerID)
        defaults.set(lastTransitionReason, forKey: Keys.lastTransitionReason)
    }
}
