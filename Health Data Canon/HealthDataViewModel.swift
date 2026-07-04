//
//  HealthDataViewModel.swift
//  Health Data Canon
//
//  Observable, main-actor state for the debug UI. Owns the `HealthKitService`,
//  drives generation/deletion, tracks progress, and keeps a small activity log.
//

import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class HealthDataViewModel {

    // MARK: Types

    enum AuthorizationState {
        case unknown
        case authorized
        case denied

        var label: String {
            switch self {
            case .unknown: "Not requested"
            case .authorized: "Authorized"
            case .denied: "Not authorized"
            }
        }
    }

    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    struct LogEntry: Identifiable {
        enum Level { case info, success, failure }
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    // MARK: Configuration (bound to the UI)

    var config = GenerationConfig.default

    /// On a physical device the destructive actions stay disabled until the
    /// user explicitly confirms they are on a dedicated test device.
    var acknowledgedDeviceRisk = false

    // MARK: Observed state

    private(set) var authorization: AuthorizationState = .unknown
    private(set) var isBusy = false
    private(set) var progress: Progress?
    private(set) var log: [LogEntry] = []

    let isHealthDataAvailable = HKHealthStore.isHealthDataAvailable()

    /// The generation/deletion controls are usable only when nothing else is
    /// running and (on device) the user has acknowledged the risk.
    var actionsEnabled: Bool {
        guard isHealthDataAvailable, !isBusy else { return false }
        return AppEnvironment.isSimulator || acknowledgedDeviceRisk
    }

    private let service = HealthKitService()

    // MARK: Actions

    func requestAuthorization() async {
        await run(startMessage: "Requesting HealthKit authorization…") {
            try await self.service.requestAuthorization()
            self.authorization = self.service.isAuthorizedToWrite ? .authorized : .denied
            switch self.authorization {
            case .authorized:
                self.append(.success, "Authorization granted.")
            default:
                self.append(.failure, "Authorization was not granted for writing.")
            }
        }
    }

    func generate() async {
        let plan = WorkoutPlanner.makePlan(for: config)
        guard !plan.isEmpty else {
            append(.failure, "Nothing to generate for the current settings.")
            return
        }

        await run(startMessage: "Generating \(plan.count) workouts…", track: true) {
            self.progress = Progress(completed: 0, total: plan.count)

            // Saving a workout is latency-bound: each `HKWorkoutBuilder` makes
            // several sequential round-trips to the health daemon. Saving them
            // one at a time badly underutilises that pipeline, so we keep a
            // bounded number of builders in flight at once and update progress
            // as each completes.
            let service = self.service
            var completed = 0

            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0

                // Prime the pipeline up to the concurrency limit.
                while next < min(Self.maxConcurrentSaves, plan.count) {
                    let blueprint = plan[next]
                    group.addTask { try await service.save(blueprint) }
                    next += 1
                }

                // As each save finishes, record progress and enqueue the next.
                while try await group.next() != nil {
                    completed += 1
                    self.progress = Progress(completed: completed, total: plan.count)
                    if next < plan.count {
                        let blueprint = plan[next]
                        group.addTask { try await service.save(blueprint) }
                        next += 1
                    }
                }
            }

            self.append(.success, "Created \(completed) workouts across \(self.config.days) days.")
        }
    }

    /// Upper bound on concurrent `HKWorkoutBuilder` saves. High enough to hide
    /// per-save IPC latency, low enough to avoid overwhelming the health daemon.
    private static let maxConcurrentSaves = 12

    func deleteAllGeneratedData() async {
        await run(startMessage: "Deleting all app-generated Health data…") {
            let count = try await self.service.deleteAllGeneratedData()
            self.append(.success, "Deleted \(count) sample\(count == 1 ? "" : "s") written by this app.")
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: Helpers

    /// Runs an async operation with shared busy-state, logging and error handling.
    private func run(
        startMessage: String,
        track: Bool = false,
        _ operation: @escaping () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        if track { progress = nil }
        append(.info, startMessage)

        do {
            try await operation()
        } catch is CancellationError {
            append(.info, "Operation cancelled.")
        } catch {
            append(.failure, error.localizedDescription)
        }

        isBusy = false
        if track { progress = nil }
    }

    private func append(_ level: LogEntry.Level, _ message: String) {
        log.insert(LogEntry(date: Date(), level: level, message: message), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }
}
