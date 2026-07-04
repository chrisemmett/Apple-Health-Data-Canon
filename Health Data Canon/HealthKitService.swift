//
//  HealthKitService.swift
//  Health Data Canon
//
//  Thin async wrapper around HealthKit for the debug tool. Responsibilities:
//   • request write authorization for the sample types we fabricate
//   • save a single `WorkoutBlueprint` using the modern `HKWorkoutBuilder`
//   • bulk-delete everything this app has written
//
//  Everything is `async`/`await` on the up-to-date HealthKit APIs — no legacy
//  completion-handler bridging. The type is `Sendable` so callers can hop it
//  across actors freely.
//

import Foundation
import HealthKit

/// Errors surfaced to the UI in human-readable form.
enum HealthKitError: LocalizedError {
    case healthDataUnavailable
    case workoutSaveFailed

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "HealthKit is not available on this device."
        case .workoutSaveFailed:
            "HealthKit did not return a saved workout."
        }
    }
}

// `HKHealthStore` is documented as thread-safe but isn't marked `Sendable`, so
// we vouch for it here.
struct HealthKitService: @unchecked Sendable {

    private let healthStore = HKHealthStore()

    // MARK: Types

    /// Quantity samples we fabricate alongside each workout.
    private static let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .activeEnergyBurned,
        .distanceWalkingRunning,
        .distanceCycling,
    ]

    private var quantityTypes: [HKQuantityType] {
        Self.quantityIdentifiers.compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    /// All sample types this app writes (and therefore is allowed to delete).
    private var managedTypes: [HKSampleType] {
        var types: [HKSampleType] = [HKObjectType.workoutType()]
        types.append(contentsOf: quantityTypes)
        return types
    }

    // MARK: Availability & Authorization

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Prompts for permission to write the workout + quantity types. We never
    /// read user data, so the read set is intentionally empty.
    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthKitError.healthDataUnavailable }
        try await healthStore.requestAuthorization(toShare: Set(managedTypes), read: [])
    }

    /// Best-effort view of whether we can currently write workouts. HealthKit
    /// deliberately never reports *read* status, but share status is reliable.
    var isAuthorizedToWrite: Bool {
        healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    // MARK: Save

    /// Saves one synthetic workout and its associated samples using
    /// `HKWorkoutBuilder`, which aggregates totals (energy, distance) for us.
    func save(_ blueprint: WorkoutBlueprint) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = blueprint.kind.activityType
        configuration.locationType = blueprint.kind.isIndoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: configuration,
            device: .local()
        )

        try await builder.beginCollection(at: blueprint.start)
        try await builder.addMetadata([
            HKMetadataKeyWorkoutBrandName: "Health Data Canon",
            HKMetadataKeyIndoorWorkout: blueprint.kind.isIndoor,
        ])

        let samples = makeSamples(for: blueprint)
        if !samples.isEmpty {
            try await builder.addSamples(samples)
        }

        try await builder.endCollection(at: blueprint.end)

        guard try await builder.finishWorkout() != nil else {
            throw HealthKitError.workoutSaveFailed
        }
    }

    // MARK: Delete

    /// Deletes every sample this app has written. HealthKit only permits an app
    /// to delete its *own* samples, so this can never touch data written by the
    /// user or other apps — but it will wipe everything this tool generated.
    /// Returns the number of samples removed.
    @discardableResult
    func deleteAllGeneratedData() async throws -> Int {
        guard isHealthDataAvailable else { throw HealthKitError.healthDataUnavailable }

        let predicate = HKQuery.predicateForSamples(withStart: .distantPast, end: .distantFuture)
        var deleted = 0
        for type in managedTypes {
            deleted += try await healthStore.deleteObjects(of: type, predicate: predicate)
        }
        return deleted
    }

    // MARK: Sample construction

    private func makeSamples(for blueprint: WorkoutBlueprint) -> [HKSample] {
        var samples: [HKSample] = []
        samples.append(contentsOf: heartRateSamples(for: blueprint))
        samples.append(contentsOf: activeEnergySamples(for: blueprint))
        if let distance = blueprint.distanceMeters {
            samples.append(contentsOf: distanceSamples(for: blueprint, meters: distance))
        }
        return samples
    }

    private func heartRateSamples(for blueprint: WorkoutBlueprint) -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              !blueprint.heartRates.isEmpty else { return [] }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let step = blueprint.duration / Double(blueprint.heartRates.count + 1)
        return blueprint.heartRates.enumerated().map { index, bpm in
            let time = blueprint.start.addingTimeInterval(step * Double(index + 1))
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: Double(bpm)),
                start: time,
                end: time
            )
        }
    }

    private func activeEnergySamples(for blueprint: WorkoutBlueprint) -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return [] }
        return evenlySplitSamples(
            type: type,
            unit: .kilocalorie(),
            total: blueprint.activeEnergyKilocalories,
            blueprint: blueprint,
            approximateSegmentSeconds: 300
        )
    }

    private func distanceSamples(for blueprint: WorkoutBlueprint, meters: Double) -> [HKQuantitySample] {
        guard let identifier = blueprint.kind.distanceIdentifier,
              let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        return evenlySplitSamples(
            type: type,
            unit: .meter(),
            total: meters,
            blueprint: blueprint,
            approximateSegmentSeconds: 300
        )
    }

    /// Splits a cumulative total (energy or distance) evenly across the workout
    /// duration into a handful of contiguous samples.
    private func evenlySplitSamples(
        type: HKQuantityType,
        unit: HKUnit,
        total: Double,
        blueprint: WorkoutBlueprint,
        approximateSegmentSeconds: Double
    ) -> [HKQuantitySample] {
        let segments = max(1, Int((blueprint.duration / approximateSegmentSeconds).rounded()))
        let perSegment = total / Double(segments)
        let segmentDuration = blueprint.duration / Double(segments)

        return (0..<segments).map { index in
            let segStart = blueprint.start.addingTimeInterval(segmentDuration * Double(index))
            let segEnd = blueprint.start.addingTimeInterval(segmentDuration * Double(index + 1))
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: perSegment),
                start: segStart,
                end: segEnd
            )
        }
    }
}
