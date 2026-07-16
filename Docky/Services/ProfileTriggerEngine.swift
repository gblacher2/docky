//
//  ProfileTriggerEngine.swift
//  Docky
//

import AppKit
import Combine
import CoreLocation
import CoreWLAN
import Foundation
import Network
import SystemConfiguration

@MainActor
final class ProfileTriggerEngine {
    static let shared = ProfileTriggerEngine()

    struct Resolution: Equatable {
        let profileID: String
        let triggerID: String?
        let reason: String
        let specificity: Int
    }

    private let profileService = ProfileService.shared
    private let automation = ProfileAutomationState.shared
    private let focusFlow = FocusFlowBridge.shared
    private var cancellables: Set<AnyCancellable> = []
    private var minuteTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var currentFrontmostBundleID: String?
    private var currentSpaceApps: Set<String> = []
    private var currentExternalDisplays: Set<String> = []
    private var currentSSID: String?
    private var currentFallbackNetworkID: String?
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var locationManager: CLLocationManager?
    private var isPathMonitorStarted = false

    private init() {}

    func start() {
        currentFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentSpaceApps = Self.appsOnActiveSpace()
        refreshDisplays()
        observeFrontmostApp()
        observeActiveSpace()
        observeDisplays()
        observeWiFi()
        scheduleMinuteTick()

        let hasConfiguredWiFiTrigger = profileService.profiles.contains { profile in
            profile.triggers.contains { trigger in
                guard case .wifi(let wifi) = trigger else { return false }
                return !wifi.ssid.isEmpty || !(wifi.fallbackNetworkID?.isEmpty ?? true)
            }
        }
        if hasConfiguredWiFiTrigger {
            locationManager = CLLocationManager()
            locationManager?.requestWhenInUseAuthorization()
        }

        focusFlow.onFocusPhaseEnded = { [weak self] in self?.stopCFAFocus(sendReset: false) }
        focusFlow.start()
        if automation.isFocusLocked,
           focusFlow.runtimeState != nil,
           !focusFlow.isFocusPhaseActive {

            let isStale = Self.isRuntimeStateStale(
                lockStart: automation.focusLockStartDate,
                fileDate: focusFlow.runtimeFileModificationDate,
                phaseEndsAt: focusFlow.runtimeState?.phaseEndsAt
            )

            if isStale {
                automation.recordWarning(String(localized: "Stale FocusFlow state ignored"))
            } else {
                stopCFAFocus(sendReset: false)
                return
            }
        }
        evaluateNow()
    }

    static func isRuntimeStateStale(lockStart: Date?, fileDate: Date?, phaseEndsAt: Date?) -> Bool {
        guard let lockStart = lockStart else { return false }
        let fDate = fileDate ?? .distantPast
        let pEndsAt = phaseEndsAt ?? .distantPast
        return max(fDate, pEndsAt) < lockStart
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        cancellables.removeAll()
        minuteTimer?.invalidate()
        minuteTimer = nil
        focusFlow.stop()
    }

    func startCFAFocus() {
        guard !automation.isFocusLocked else { return }
        guard !profileService.focusProfileID.isEmpty,
              profileService.profiles.contains(where: { $0.id == profileService.focusProfileID }) else {
            automation.recordWarning(String(localized: "Choose a CFA Study profile in Settings first."))
            return
        }
        automation.beginFocusLock(previousProfileID: profileService.activeProfileID)
        profileService.setActiveProfile(id: profileService.focusProfileID)
        focusFlow.startFocus()
    }

    func stopCFAFocus() {
        stopCFAFocus(sendReset: true)
    }

    func pauseAutomation(_ choice: ProfileAutomationState.PauseChoice) {
        automation.pause(choice)
        debounceTask?.cancel()
    }

    func resumeAutomation() {
        automation.resume()
        evaluateNow()
    }

    func evaluateNow() {
        debounceTask?.cancel()
        debounceTask = nil
        _ = automation.clearExpiredPauseIfNeeded()

        if automation.isFocusLocked {
            guard !profileService.focusProfileID.isEmpty else {
                stopCFAFocus(sendReset: false)
                return
            }
            if profileService.activeProfileID != profileService.focusProfileID {
                profileService.setActiveProfile(id: profileService.focusProfileID)
            }
            automation.recordTransition(triggerID: "focusflow", reason: String(localized: "CFA Focus lock"))
            return
        }

        guard !automation.isPaused else { return }
        guard let resolution = bestResolution() else { return }
        if resolution.profileID != profileService.activeProfileID {
            profileService.setActiveProfile(id: resolution.profileID)
        }
        automation.recordTransition(triggerID: resolution.triggerID, reason: resolution.reason)
    }

    func scheduleEvaluation() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.evaluateNow()
        }
    }

    private func stopCFAFocus(sendReset: Bool) {
        guard automation.isFocusLocked else { return }
        if sendReset { focusFlow.stopFocus() }
        let previous = automation.endFocusLock()
        if let previous,
           profileService.profiles.contains(where: { $0.id == previous }) {
            profileService.setActiveProfile(id: previous)
        }
        evaluateNow()
    }

    private func bestResolution(now: Date = Date()) -> Resolution? {
        Self.resolve(
            profiles: profileService.profiles,
            fallbackProfileID: profileService.fallbackProfileID,
            now: now,
            frontmost: currentFrontmostBundleID,
            spaceApps: currentSpaceApps,
            displays: currentExternalDisplays,
            ssid: currentSSID,
            fallbackID: currentFallbackNetworkID
        )
    }

    /// Pure resolution entry point shared by the live engine and unit tests.
    static func resolve(
        profiles: [DockProfile],
        fallbackProfileID: String,
        now: Date,
        frontmost: String?,
        spaceApps: Set<String>,
        displays: Set<String>,
        ssid: String?,
        fallbackID: String?
    ) -> Resolution? {
        struct Candidate {
            let profile: DockProfile
            let trigger: ProfileTrigger
        }

        var best: Candidate?
        for profile in profiles {
            for trigger in profile.triggers where Self.trigger(
                trigger,
                matches: now,
                frontmost: frontmost,
                spaceApps: spaceApps,
                displays: displays,
                ssid: ssid,
                fallbackID: fallbackID
            ) {
                guard let current = best else {
                    best = Candidate(profile: profile, trigger: trigger)
                    continue
                }
                if trigger.specificity > current.trigger.specificity ||
                    (trigger.specificity == current.trigger.specificity && profile.dateCreated < current.profile.dateCreated) {
                    best = Candidate(profile: profile, trigger: trigger)
                }
            }
        }

        if let best {
            return Resolution(
                profileID: best.profile.id,
                triggerID: best.trigger.id,
                reason: Self.reason(for: best.trigger),
                specificity: best.trigger.specificity
            )
        }

        guard profiles.contains(where: { $0.id == fallbackProfileID }) else { return nil }
        return Resolution(
            profileID: fallbackProfileID,
            triggerID: nil,
            reason: String(localized: "Daily fallback"),
            specificity: 0
        )
    }

    private static func reason(for trigger: ProfileTrigger) -> String {
        switch trigger {
        case .frontmostApp: String(localized: "Frontmost app")
        case .space: String(localized: "Active Space")
        case .display: String(localized: "External display")
        case .wifi: String(localized: "Wi-Fi network")
        case .timeOfDay: String(localized: "Time schedule")
        }
    }

    static func appsOnActiveSpace() -> Set<String> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: Set<String> = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            result.insert(bundleID)
        }
        return result
    }

    private func observeDisplays() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.refreshDisplays()
                self?.scheduleEvaluation()
            }
            .store(in: &cancellables)
    }

    private func refreshDisplays() {
        currentExternalDisplays = Set(NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(number) == 0 else { return nil }
            return screen.localizedName
        })
    }

    private func observeWiFi() {
        guard !isPathMonitorStarted else { return }
        isPathMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshWiFi() }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .background))
        refreshWiFi()
    }

    private func refreshWiFi() {
        currentSSID = CWWiFiClient.shared().interface()?.ssid()
        currentFallbackNetworkID = Self.getFallbackNetworkID()
        scheduleEvaluation()
    }

    static func getFallbackNetworkID() -> String? {
        let store = SCDynamicStoreCreate(nil, "Docky" as CFString, nil, nil)
        if let info = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            return info["Router"] as? String
        }
        return nil
    }

    private func observeFrontmostApp() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let self else { return }
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                currentFrontmostBundleID = app?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                currentSpaceApps = Self.appsOnActiveSpace()
                scheduleEvaluation()
            }
            .store(in: &cancellables)
    }

    private func observeActiveSpace() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.currentSpaceApps = Self.appsOnActiveSpace()
                self?.scheduleEvaluation()
            }
            .store(in: &cancellables)
    }

    private func scheduleMinuteTick() {
        let calendar = Calendar.current
        let now = Date()
        let nextMinute = calendar.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(60)
        minuteTimer = Timer.scheduledTimer(withTimeInterval: max(nextMinute.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.startRepeatingMinuteTimer() }
        }
    }

    private func startRepeatingMinuteTimer() {
        evaluateNow()
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateNow() }
        }
    }

    private static func trigger(
        _ trigger: ProfileTrigger,
        matches now: Date,
        frontmost: String?,
        spaceApps: Set<String>,
        displays: Set<String>,
        ssid: String?,
        fallbackID: String?
    ) -> Bool {
        switch trigger {
        case .timeOfDay(let value): return value.matches(date: now)
        case .frontmostApp(let value): return frontmost == value.bundleIdentifier
        case .space(let value): return spaceApps.contains(value.bundleIdentifier)
        case .display(let value):
            if let name = value.displayName, !name.isEmpty { return displays.contains(name) }
            return !displays.isEmpty
        case .wifi(let value):
            if !value.ssid.isEmpty, value.ssid == ssid { return true }
            if let fallback = value.fallbackNetworkID, !fallback.isEmpty, fallback == fallbackID { return true }
            return false
        }
    }
}
