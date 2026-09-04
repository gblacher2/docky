import XCTest
@testable import Docky

@MainActor
final class GabrielGlassCoreTests: XCTestCase {
    private func profile(
        id: String,
        created: TimeInterval,
        triggers: [ProfileTrigger] = []
    ) -> DockProfile {
        DockProfile(
            id: id,
            name: id,
            dateCreated: Date(timeIntervalSince1970: created),
            triggers: triggers
        )
    }

    func testTriggerPrecedenceAndDailyFallback() {
        let daily = profile(id: "daily", created: 0)
        let timed = profile(id: "timed", created: 1, triggers: [
            .timeOfDay(.init(
                id: "time",
                startMinuteOfDay: 0,
                endMinuteOfDay: 1_439,
                weekdays: [1, 2, 3, 4, 5, 6, 7]
            )),
        ])
        let desk = profile(id: "desk", created: 2, triggers: [
            .display(.init(id: "display")),
        ])
        let build = profile(id: "build", created: 3, triggers: [
            .frontmostApp(.init(id: "app", bundleIdentifier: "com.apple.dt.Xcode")),
        ])
        let profiles = [daily, timed, desk, build]
        let now = Date(timeIntervalSince1970: 12 * 60 * 60)

        let app = ProfileTriggerEngine.resolve(
            profiles: profiles,
            fallbackProfileID: "daily",
            now: now,
            frontmost: "com.apple.dt.Xcode",
            spaceApps: [],
            displays: ["Studio Display"],
            ssid: nil,
            fallbackID: nil
        )
        XCTAssertEqual(app?.profileID, "build")
        XCTAssertEqual(app?.specificity, 3)

        let display = ProfileTriggerEngine.resolve(
            profiles: profiles,
            fallbackProfileID: "daily",
            now: now,
            frontmost: nil,
            spaceApps: [],
            displays: ["Studio Display"],
            ssid: nil,
            fallbackID: nil
        )
        XCTAssertEqual(display?.profileID, "desk")
        XCTAssertEqual(display?.specificity, 2)

        let time = ProfileTriggerEngine.resolve(
            profiles: profiles,
            fallbackProfileID: "daily",
            now: now,
            frontmost: nil,
            spaceApps: [],
            displays: [],
            ssid: nil,
            fallbackID: nil
        )
        XCTAssertEqual(time?.profileID, "timed")
        XCTAssertEqual(time?.specificity, 1)

        let fallback = ProfileTriggerEngine.resolve(
            profiles: [daily],
            fallbackProfileID: "daily",
            now: now,
            frontmost: nil,
            spaceApps: [],
            displays: [],
            ssid: nil,
            fallbackID: nil
        )
        XCTAssertEqual(fallback?.profileID, "daily")
        XCTAssertNil(fallback?.triggerID)
        XCTAssertEqual(fallback?.specificity, 0)
    }

    func testOlderProfileWinsSpecificityTie() {
        let older = profile(id: "older", created: 1, triggers: [
            .frontmostApp(.init(id: "older-app", bundleIdentifier: "com.apple.dt.Xcode")),
        ])
        let newer = profile(id: "newer", created: 2, triggers: [
            .space(.init(id: "newer-space", bundleIdentifier: "com.apple.dt.Xcode")),
        ])

        let result = ProfileTriggerEngine.resolve(
            profiles: [newer, older],
            fallbackProfileID: "older",
            now: Date(),
            frontmost: "com.apple.dt.Xcode",
            spaceApps: ["com.apple.dt.Xcode"],
            displays: [],
            ssid: nil,
            fallbackID: nil
        )
        XCTAssertEqual(result?.profileID, "older")
        XCTAssertEqual(result?.triggerID, "older-app")
    }

    func testPauseExpiryPersistsAcrossStateRestoration() {
        let suite = "GabrielGlassCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date().addingTimeInterval(3_600)
        let state = ProfileAutomationState(defaults: defaults)
        state.pause(.thirtyMinutes, now: start)

        let restored = ProfileAutomationState(defaults: defaults)
        XCTAssertEqual(restored.pauseExpiry, start.addingTimeInterval(1_800))
        XCTAssertFalse(restored.clearExpiredPauseIfNeeded(now: start.addingTimeInterval(1_799)))
        XCTAssertTrue(restored.clearExpiredPauseIfNeeded(now: start.addingTimeInterval(1_800)))
        XCTAssertNil(restored.pauseExpiry)
    }

    func testFocusCompletionAndPriorProfileRestorationState() {
        let focus = FocusFlowBridge.RuntimeState(
            phase: "focus",
            activePhase: "focus",
            isRunning: true,
            phaseEndsAt: nil
        )
        let paused = FocusFlowBridge.RuntimeState(
            phase: "paused",
            activePhase: "focus",
            isRunning: true,
            phaseEndsAt: nil
        )
        let rest = FocusFlowBridge.RuntimeState(
            phase: "rest",
            activePhase: "rest",
            isRunning: true,
            phaseEndsAt: nil
        )
        XCTAssertFalse(FocusFlowBridge.focusPhaseEnded(previous: focus, current: paused))
        XCTAssertTrue(FocusFlowBridge.focusPhaseEnded(previous: paused, current: rest))

        let suite = "GabrielGlassFocusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = ProfileAutomationState(defaults: defaults)
        automation.beginFocusLock(previousProfileID: "desk")

        let restored = ProfileAutomationState(defaults: defaults)
        XCTAssertTrue(restored.isFocusLocked)
        XCTAssertEqual(restored.previousProfileID, "desk")
        XCTAssertEqual(restored.endFocusLock(), "desk")
        XCTAssertFalse(restored.isFocusLocked)
        XCTAssertNil(restored.previousProfileID)
        XCTAssertNil(restored.focusLockStartDate)
    }

    func testFocusLockStartDatePersistsAcrossStateRestoration() {
        let suite = "GabrielGlassFocusTests.Date.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let automation = ProfileAutomationState(defaults: defaults)
        automation.beginFocusLock(previousProfileID: "desk")
        
        let start = automation.focusLockStartDate
        XCTAssertNotNil(start)

        let restored = ProfileAutomationState(defaults: defaults)
        XCTAssertEqual(restored.focusLockStartDate?.timeIntervalSince1970, start?.timeIntervalSince1970)
        
        restored.endFocusLock()
        let cleared = ProfileAutomationState(defaults: defaults)
        XCTAssertNil(cleared.focusLockStartDate)
    }

    func testLegacyDockProfileDecodingDefaultsNewFields() throws {
        let encoded = try JSONEncoder().encode(profile(id: "legacy", created: 0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "accent")
        object.removeValue(forKey: "triggers")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DockProfile.self, from: legacy)
        XCTAssertNil(decoded.accent)
        XCTAssertEqual(decoded.triggers, [])
    }

    func testSetupRejectsGloballyDuplicatedTileIdentifiers() throws {
        let tile = SetupTile(
            id: "duplicate",
            kind: "launchpad",
            bundleIdentifier: nil,
            widgetKind: nil,
            ownerBundleIdentifier: nil,
            span: nil,
            widgets: nil,
            folderName: nil,
            apps: nil,
            settings: nil
        )
        let manifest = PersonalSetupManifest(
            schemaVersion: PersonalSetupImportService.schemaVersion,
            id: "test",
            version: "1",
            themeID: nil,
            fallbackProfileID: "daily",
            focusProfileID: "study",
            activeProfileID: "daily",
            appearance: .init(tileSize: 44, largeSize: 56, magnification: true),
            behavior: .init(orientation: "bottom", autohide: true, autohideDelay: 0.25),
            profiles: [
                .init(
                    id: "daily",
                    name: "Daily",
                    symbolName: "house.fill",
                    accent: "blue",
                    triggers: [],
                    tiles: [tile],
                    hiddenAppBundleIdentifiers: nil
                ),
                .init(
                    id: "study",
                    name: "Study",
                    symbolName: "books.vertical.fill",
                    accent: "indigo",
                    triggers: [],
                    tiles: [tile],
                    hiddenAppBundleIdentifiers: nil
                ),
            ]
        )

        XCTAssertThrowsError(try PersonalSetupImportService.shared.preview(manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("globally unique"))
        }
    }

    func testPersonalWidgetContractsAreAvailableWithoutInstalledBundles() throws {
        XCTAssertEqual(PersonalSetupImportService.knownPersonalWidgetFieldTypes.count, 5)
        let loadedButUnsafe = [
            WidgetSettingsField(id: "apiToken", label: "Token", type: .text),
        ]
        let contract = try PersonalSetupImportService.fieldTypes(
            forExternalWidgetIdentifier: "com.gblacher.markets-watchlist",
            loadedFields: loadedButUnsafe
        )
        XCTAssertEqual(contract["apiToken"], .secureText)
        XCTAssertEqual(contract["refreshMinutes"], .select)
    }

    func testSecureAndUnknownSettingsAreExcludedFromSetupImport() throws {
        let markets = try XCTUnwrap(
            PersonalSetupImportService.knownPersonalWidgetFieldTypes["com.gblacher.markets-watchlist"]
        )
        XCTAssertNoThrow(try PersonalSetupImportService.validateSettings(
            ["tickers": .string("SPY,AAPL"), "refreshMinutes": .string("5")],
            fieldsByID: markets
        ))
        XCTAssertThrowsError(try PersonalSetupImportService.validateSettings(
            ["apiToken": .string("secret")],
            fieldsByID: markets
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("secureText"))
        }
        XCTAssertThrowsError(try PersonalSetupImportService.validateSettings(
            ["unrecognizedSecret": .string("secret")],
            fieldsByID: markets
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unknown widget settings"))
        }
    }
    func testKeyboardAndAccessibilityActivationRouting() {
        XCTAssertTrue(TileView.shouldRouteKeyPressToActivation(.space), "Space key should route to activation")
        XCTAssertTrue(TileView.shouldRouteKeyPressToActivation(.return), "Return key should route to activation")
        XCTAssertFalse(TileView.shouldRouteKeyPressToActivation(.escape), "Escape key should not route to activation")
    }

    func testSecureSettingsRevisionInvalidation() {
        let store = TileStore.shared
        store.refreshWidgetConfiguration(tileID: "secure1")
        let initialRevision = store.widgetRevisions["secure1"] ?? 0
        
        store.refreshWidgetConfiguration(tileID: "secure1")
        let newRevision = store.widgetRevisions["secure1"] ?? 0
        
        XCTAssertGreaterThan(newRevision, initialRevision, "Revision should bump on refresh to force external widget view rebuild.")
    }

    func testReduceMotionAnimationSelection() {
        XCTAssertEqual(WidgetExpansionWindowController.resolvedAnimationDuration(reduceMotion: true), 0, "Animation duration should be 0 when reduce motion is enabled")
        XCTAssertGreaterThan(WidgetExpansionWindowController.resolvedAnimationDuration(reduceMotion: false), 0, "Animation duration should be > 0 when reduce motion is disabled")
    }

    func testStaleVersusFreshRuntimeReconciliation() {
        let lockStart = Date(timeIntervalSince1970: 1000)
        let staleFile = Date(timeIntervalSince1970: 900)
        let stalePhase = Date(timeIntervalSince1970: 950)
        let freshFile = Date(timeIntervalSince1970: 1050)
        let freshPhase = Date(timeIntervalSince1970: 1050)
        
        XCTAssertTrue(ProfileTriggerEngine.isRuntimeStateStale(lockStart: lockStart, fileDate: staleFile, phaseEndsAt: stalePhase), "Should be stale if both dates predate lock")
        XCTAssertFalse(ProfileTriggerEngine.isRuntimeStateStale(lockStart: lockStart, fileDate: freshFile, phaseEndsAt: stalePhase), "Should be fresh if file date is newer")
        XCTAssertFalse(ProfileTriggerEngine.isRuntimeStateStale(lockStart: lockStart, fileDate: staleFile, phaseEndsAt: freshPhase), "Should be fresh if phase end date is newer")
        XCTAssertTrue(ProfileTriggerEngine.isRuntimeStateStale(lockStart: lockStart, fileDate: nil, phaseEndsAt: nil), "Should be stale if timestamps are absent but lock exists")
        XCTAssertFalse(ProfileTriggerEngine.isRuntimeStateStale(lockStart: nil, fileDate: staleFile, phaseEndsAt: stalePhase), "Should not be stale (legacy case) if lockStart is nil")
    }

    func testDockyUserDefaultsStability() {
        let testSuite1 = DockyUserDefaults.standard
        let testSuite2 = DockyUserDefaults.standard
        XCTAssertTrue(testSuite1 === testSuite2, "DockyUserDefaults.standard should return the same cached instance within the test process")
        XCTAssertNotEqual(testSuite1, UserDefaults.standard, "DockyUserDefaults.standard should not be the production UserDefaults.standard during tests")
    }
}
