//
//  AppEnvironment.swift
//  Health Data Canon
//
//  Small helpers describing *where* this build is running. This is a
//  developer-only tool that writes and deletes real HealthKit samples, so the
//  UI leans heavily on `isSimulator` to warn when it is running somewhere it
//  shouldn't be.
//

import Foundation

enum AppEnvironment {

    /// `true` when running on the iOS Simulator, `false` on a physical device.
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Human-readable description of the current run destination.
    static var runningDestination: String {
        isSimulator ? "Simulator" : "Physical Device"
    }
}
