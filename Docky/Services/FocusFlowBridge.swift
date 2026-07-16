//
//  FocusFlowBridge.swift
//  Docky
//

import AppKit
import Foundation
import Observation

private struct SendableFocusFlowObserver: @unchecked Sendable {
    let value: any NSObjectProtocol
}

@MainActor
@Observable
final class FocusFlowBridge {
    static let shared = FocusFlowBridge()

    struct RuntimeState: Decodable, Equatable {
        let phase: String
        let activePhase: String
        let isRunning: Bool
        let phaseEndsAt: Date?

        var isFocusPhaseActive: Bool {
            phase == "focus" || (phase == "paused" && activePhase == "focus")
        }
    }

    private(set) var runtimeState: RuntimeState?
    private(set) var runtimeFileModificationDate: Date?
    private(set) var isApplicationRunning = false
    var isFocusPhaseActive: Bool {
        runtimeState?.isFocusPhaseActive == true
    }
    var onFocusPhaseEnded: (() -> Void)?

    private var observer: SendableFocusFlowObserver?
    private var fallbackTimer: Timer?
    private var didReportCompletedFocus = false

    static func focusPhaseEnded(previous: RuntimeState?, current: RuntimeState) -> Bool {
        previous?.isFocusPhaseActive == true && !current.isFocusPhaseActive
    }

    private static let bundleIdentifier = "com.gabrielblacher.FocusFlow"
    private static let stateChangedName = Notification.Name("com.gblacher.focusflow.stateChanged")
    private static let commandName = Notification.Name("com.gblacher.focusflow.command")

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = SendableFocusFlowObserver(value: DistributedNotificationCenter.default().addObserver(
            forName: Self.stateChangedName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        })
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer.value)
            self.observer = nil
        }
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    func startFocus() {
        refresh()
        if isApplicationRunning {
            if runtimeState?.isRunning == true, runtimeState?.phase == "focus" { return }
            post(command: "startFocus")
            return
        }

        guard launchApplication() else {
            ProfileAutomationState.shared.recordWarning(String(localized: "FocusFlow could not be found. CFA Study remains active."))
            return
        }
        ProfileAutomationState.shared.recordWarning(String(localized: "Starting FocusFlow…"))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            self.post(command: "startFocus")
            self.refresh()
        }
    }

    func stopFocus() {
        if isApplicationRunning { post(command: "reset") }
    }

    func refresh() {
        isApplicationRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        guard let data = try? Data(contentsOf: runtimeURL) else {
            runtimeState = nil
            runtimeFileModificationDate = nil
            return
        }
        let previousState = runtimeState
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(RuntimeState.self, from: data) else { return }
        runtimeState = state
        
        let attrs = try? FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        runtimeFileModificationDate = attrs?[.modificationDate] as? Date

        let focusIsActive = isFocusPhaseActive
        if focusIsActive {
            didReportCompletedFocus = false
            ProfileAutomationState.shared.recordWarning(nil)
        } else if Self.focusPhaseEnded(previous: previousState, current: state), !didReportCompletedFocus {
            didReportCompletedFocus = true
            onFocusPhaseEnded?()
        }
    }

    private var runtimeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusFlow", isDirectory: true)
            .appendingPathComponent("runtime.json")
    }

    private func launchApplication() -> Bool {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        }
        let fallback = URL(fileURLWithPath: "/Applications/FocusFlow.app")
        guard FileManager.default.fileExists(atPath: fallback.path) else { return false }
        NSWorkspace.shared.open(fallback)
        return true
    }

    private func post(command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.commandName,
            object: command,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
