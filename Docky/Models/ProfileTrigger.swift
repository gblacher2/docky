//
//  ProfileTrigger.swift
//  Docky
//
//  Per-profile rules that switch the active dock profile automatically
//  based on system signals. Phase 1: time-of-day, frontmost app, and
//  Mission Control space. Phase 2 will add Wi-Fi SSID and Bluetooth
//  proximity, both of which require lazy permission prompts.
//
//  Resolution: `ProfileTriggerEngine` collects every trigger across all
//  profiles, ranks matches by `specificity` (higher wins), and falls
//  through to `Profile.dateCreated` order on ties.
//

import Foundation

enum ProfileTrigger: Codable, Equatable, Identifiable {
    case timeOfDay(TimeOfDayTrigger)
    case frontmostApp(FrontmostAppTrigger)
    case space(SpaceTrigger)
    case display(DisplayTrigger)
    case wifi(WiFiTrigger)

    var id: String {
        switch self {
        case .timeOfDay(let trigger): return trigger.id
        case .frontmostApp(let trigger): return trigger.id
        case .space(let trigger): return trigger.id
        case .display(let trigger): return trigger.id
        case .wifi(let trigger): return trigger.id
        }
    }

    /// Higher specificity beats lower when multiple triggers match.
    /// Focus lock is resolved before this model. App and Space triggers
    /// share the highest environmental tier, followed by display/Wi-Fi,
    /// time-of-day, and finally the configured fallback profile.
    var specificity: Int {
        switch self {
        case .space, .frontmostApp: return 3
        case .wifi, .display: return 2
        case .timeOfDay: return 1
        }
    }
}

/// Fires while the local time falls inside `[startMinuteOfDay,
/// endMinuteOfDay)` on any of the listed weekdays. Minute-of-day is 0
/// (00:00) up to 1439 (23:59). Wraparound (e.g. 22:00 → 06:00) is
/// supported by `endMinuteOfDay < startMinuteOfDay`.
struct TimeOfDayTrigger: Codable, Equatable, Identifiable {
    let id: String
    var startMinuteOfDay: Int
    var endMinuteOfDay: Int
    /// Weekdays where this trigger is active. `1 == Sunday`,
    /// `7 == Saturday` (matches `Calendar.component(.weekday, from:)`).
    var weekdays: Set<Int>

    init(
        id: String = UUID().uuidString,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 18 * 60,
        weekdays: Set<Int> = [2, 3, 4, 5, 6]
    ) {
        self.id = id
        self.startMinuteOfDay = max(0, min(startMinuteOfDay, 1439))
        self.endMinuteOfDay = max(0, min(endMinuteOfDay, 1439))
        self.weekdays = weekdays
    }

    func matches(date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        guard weekdays.contains(weekday) else { return false }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinuteOfDay == endMinuteOfDay {
            return false
        }
        if startMinuteOfDay < endMinuteOfDay {
            return minuteOfDay >= startMinuteOfDay && minuteOfDay < endMinuteOfDay
        }
        // Wraparound (e.g. 22:00 → 06:00 the next morning).
        return minuteOfDay >= startMinuteOfDay || minuteOfDay < endMinuteOfDay
    }
}

/// Fires while the user's frontmost application matches the bound
/// bundle identifier.
struct FrontmostAppTrigger: Codable, Equatable, Identifiable {
    let id: String
    var bundleIdentifier: String

    init(id: String = UUID().uuidString, bundleIdentifier: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Fires while the user is on a Mission Control space that contains a
/// visible window of the bound app. Identifying spaces by their app
/// (rather than positional index) survives macOS's automatic space
/// rearrangement based on most-recently-used apps. The common case is
/// a fullscreen app on its own dedicated space.
struct SpaceTrigger: Codable, Equatable, Identifiable {
    let id: String
    var bundleIdentifier: String

    init(id: String = UUID().uuidString, bundleIdentifier: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Fires while a matching external display is connected.
struct DisplayTrigger: Codable, Equatable, Identifiable {
    let id: String
    /// When nil/empty, matches ANY external (non-built-in) display.
    /// Otherwise matches a display whose localized name equals this.
    var displayName: String?

    init(id: String = UUID().uuidString, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Fires while connected to a Wi-Fi network whose SSID matches `ssid`.
struct WiFiTrigger: Codable, Equatable, Identifiable {
    let id: String
    var ssid: String
    /// Fallback comparison value (e.g. gateway/subnet) if SSID cannot be read
    /// due to missing Location permission.
    var fallbackNetworkID: String?

    init(id: String = UUID().uuidString, ssid: String = "", fallbackNetworkID: String? = nil) {
        self.id = id
        self.ssid = ssid
        self.fallbackNetworkID = fallbackNetworkID
    }
}
