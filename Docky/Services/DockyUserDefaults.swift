//
//  DockyUserDefaults.swift
//  Docky
//

import Foundation

public enum DockyUserDefaults {
    private static let testSuiteName = "gt.quintero.Docky.Test.\(UUID().uuidString)"
    private static let testSuite = UserDefaults(suiteName: testSuiteName)!
    
    /// Returns UserDefaults.standard in production,
    /// or a volatile test suite if running under XCTest, to prevent test isolation leaks.
    public static var standard: UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return testSuite
        }
        return UserDefaults.standard
    }
}
