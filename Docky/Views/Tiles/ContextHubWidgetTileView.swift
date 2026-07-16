//
//  ContextHubWidgetTileView.swift
//  Docky
//

import AppKit
import SwiftUI

extension ProfileAccent {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .orange: .orange
        case .teal: .teal
        }
    }
}

struct ContextHubWidgetTileView: View {
    let cornerRadius: CGFloat
    let isExpanded: Bool

    @Bindable private var profiles = ProfileService.shared
    @Bindable private var automation = ProfileAutomationState.shared

    @Bindable private var preferences = DockyPreferences.shared

    private var accent: Color { Color(nsColor: preferences.effectiveActiveIndicatorColor) }

    var body: some View {
        Group {
            if isExpanded { expandedContent } else { compactContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(accent.opacity(0.28), lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context Hub")
        .accessibilityValue("\(profiles.activeProfile?.name ?? String(localized: "Profile")), \(statusText)")
    }

    private var compactContent: some View {
        HStack(spacing: 8) {
            Image(systemName: profiles.activeProfile?.symbolName ?? "circle.grid.3x3.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(profiles.activeProfile?.name ?? String(localized: "Profile"))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: profiles.activeProfile?.symbolName ?? "circle.grid.3x3.fill")
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profiles.activeProfile?.name ?? String(localized: "Profile"))
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(profiles.profiles) { profile in
                    Button {
                        profiles.setActiveProfile(id: profile.id)
                    } label: {
                        Label(profile.name, systemImage: profile.symbolName)
                            .font(.caption.weight(profile.id == profiles.activeProfileID ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(profile.id == profiles.activeProfileID ? accent : nil)
                    .disabled(automation.isFocusLocked && profile.id != profiles.focusProfileID)
                    .accessibilityAddTraits(profile.id == profiles.activeProfileID ? .isSelected : [])
                }
            }

            HStack(spacing: 6) {
                Button {
                    if automation.isFocusLocked {
                        ProfileTriggerEngine.shared.stopCFAFocus()
                    } else {
                        ProfileTriggerEngine.shared.startCFAFocus()
                    }
                } label: {
                    Label(
                        automation.isFocusLocked ? String(localized: "Stop CFA Focus") : String(localized: "Start CFA Focus"),
                        systemImage: automation.isFocusLocked ? "stop.fill" : "timer"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }

            HStack(spacing: 6) {
                if automation.isPaused {
                    Button("Resume Automation") { ProfileTriggerEngine.shared.resumeAutomation() }
                        .buttonStyle(.bordered)
                } else {
                    Menu("Pause Automation") {
                        Button("30 Minutes") { ProfileTriggerEngine.shared.pauseAutomation(.thirtyMinutes) }
                        Button("1 Hour") { ProfileTriggerEngine.shared.pauseAutomation(.oneHour) }
                        Button("Until Tomorrow") { ProfileTriggerEngine.shared.pauseAutomation(.untilTomorrow) }
                        Button("Indefinitely") { ProfileTriggerEngine.shared.pauseAutomation(.indefinitely) }
                    }
                    .menuStyle(.borderlessButton)
                }
                Spacer()
                Button("Settings…") {
                    (NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)
                }
                .buttonStyle(.link)
            }

            if let warning = automation.lastWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }

    private var statusText: String {
        if automation.isFocusLocked { return String(localized: "CFA Focus locked") }
        if let paused = automation.pauseDescription { return paused }
        return automation.lastTransitionReason
    }

    private var statusColor: Color {
        if automation.isFocusLocked { return .indigo }
        if automation.isPaused { return .yellow }
        return accent
    }
}
