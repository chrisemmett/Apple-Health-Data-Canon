//
//  WorkoutPlan.swift
//  Health Data Canon
//
//  Pure, HealthKit-free description of the synthetic data we want to create.
//  Keeping the "what to generate" model separate from the "how to save it"
//  service (`HealthKitService`) makes the generation logic easy to read, tweak,
//  and test without touching HealthKit.
//

import Foundation
import HealthKit

/// A category of workout the generator knows how to fabricate.
enum WorkoutKind: String, CaseIterable, Identifiable, Sendable {
    case run
    case walk
    case cycle
    case strength
    case hiit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .run: "Outdoor Run"
        case .walk: "Walk"
        case .cycle: "Cycle"
        case .strength: "Strength"
        case .hiit: "HIIT"
        }
    }

    /// SF Symbol used to represent the kind in the UI.
    var symbolName: String {
        switch self {
        case .run: "figure.run"
        case .walk: "figure.walk"
        case .cycle: "figure.outdoor.cycle"
        case .strength: "dumbbell"
        case .hiit: "figure.highintensity.intervaltraining"
        }
    }

    var activityType: HKWorkoutActivityType {
        switch self {
        case .run: .running
        case .walk: .walking
        case .cycle: .cycling
        case .strength: .traditionalStrengthTraining
        case .hiit: .highIntensityIntervalTraining
        }
    }

    var isIndoor: Bool {
        switch self {
        case .strength, .hiit: true
        case .run, .walk, .cycle: false
        }
    }

    /// The distance quantity type this kind records, if any.
    var distanceIdentifier: HKQuantityTypeIdentifier? {
        switch self {
        case .run, .walk: .distanceWalkingRunning
        case .cycle: .distanceCycling
        case .strength, .hiit: nil
        }
    }
}

/// A fully-resolved, ready-to-save synthetic workout. All randomness has been
/// baked in by the time a blueprint exists, so saving is deterministic.
struct WorkoutBlueprint: Identifiable, Sendable {
    let id = UUID()
    let kind: WorkoutKind
    let start: Date
    let duration: TimeInterval
    /// Total distance in meters, or `nil` for non-distance activities.
    let distanceMeters: Double?
    let activeEnergyKilocalories: Double
    /// A short heart-rate curve (bpm) sampled across the workout.
    let heartRates: [Int]

    var end: Date { start.addingTimeInterval(duration) }
}

/// How much synthetic data to fabricate.
struct GenerationConfig: Sendable {
    var days: Int
    var workoutsPerDay: Int

    var totalWorkouts: Int { max(0, days) * max(0, workoutsPerDay) }

    static let `default` = GenerationConfig(days: 182, workoutsPerDay: 2)
}

/// Turns a `GenerationConfig` into a concrete list of `WorkoutBlueprint`s,
/// spreading workouts realistically across each day and rotating through the
/// available workout kinds so the generated history looks varied.
enum WorkoutPlanner {

    static func makePlan(
        for config: GenerationConfig,
        endingAt now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkoutBlueprint] {
        guard config.days > 0, config.workoutsPerDay > 0 else { return [] }

        let kinds = WorkoutKind.allCases
        var blueprints: [WorkoutBlueprint] = []
        blueprints.reserveCapacity(config.totalWorkouts)

        for dayOffset in 0..<config.days {
            guard let midnight = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: calendar.startOfDay(for: now)
            ) else { continue }

            for slot in 0..<config.workoutsPerDay {
                let kind = kinds[(dayOffset + slot) % kinds.count]
                let start = startTime(for: slot, of: config.workoutsPerDay, on: midnight, calendar: calendar)

                // Skip anything that would land in the future (today's later slots).
                guard start <= now else { continue }

                blueprints.append(makeBlueprint(kind: kind, start: start))
            }
        }

        return blueprints
    }

    /// Spread the day's workouts between roughly 06:00 and 20:00 with a little jitter.
    private static func startTime(
        for slot: Int,
        of perDay: Int,
        on midnight: Date,
        calendar: Calendar
    ) -> Date {
        let window = 14.0 * 3600 // 06:00 -> 20:00
        let base = 6.0 * 3600
        let step = perDay > 1 ? window / Double(perDay) : window / 2
        let jitter = Double(Int.random(in: 0..<Int(min(step, 45 * 60))))
        let offset = base + step * Double(slot) + jitter
        return midnight.addingTimeInterval(offset)
    }

    private static func makeBlueprint(kind: WorkoutKind, start: Date) -> WorkoutBlueprint {
        switch kind {
        case .run:
            return blueprint(kind, start, minutes: 25...50, kcal: 220...520,
                             meters: 3_500...9_000, hr: (baseline: 120...135, peak: 155...182))
        case .walk:
            return blueprint(kind, start, minutes: 30...60, kcal: 120...260,
                             meters: 2_500...6_000, hr: (baseline: 95...110, peak: 120...138))
        case .cycle:
            return blueprint(kind, start, minutes: 30...75, kcal: 300...650,
                             meters: 8_000...25_000, hr: (baseline: 115...130, peak: 150...175))
        case .strength:
            return blueprint(kind, start, minutes: 25...55, kcal: 150...340,
                             meters: nil, hr: (baseline: 100...120, peak: 135...160))
        case .hiit:
            return blueprint(kind, start, minutes: 15...35, kcal: 200...420,
                             meters: nil, hr: (baseline: 115...130, peak: 160...185))
        }
    }

    private static func blueprint(
        _ kind: WorkoutKind,
        _ start: Date,
        minutes: ClosedRange<Int>,
        kcal: ClosedRange<Int>,
        meters: ClosedRange<Int>?,
        hr: (baseline: ClosedRange<Int>, peak: ClosedRange<Int>)
    ) -> WorkoutBlueprint {
        WorkoutBlueprint(
            kind: kind,
            start: start,
            duration: TimeInterval(Int.random(in: minutes) * 60),
            distanceMeters: meters.map { Double(Int.random(in: $0)) },
            activeEnergyKilocalories: Double(Int.random(in: kcal)),
            heartRates: heartRateCurve(
                baseline: Int.random(in: hr.baseline),
                peak: Int.random(in: hr.peak),
                count: 10
            )
        )
    }

    /// A simple triangular ramp up to `peak` and back down, with light jitter.
    private static func heartRateCurve(baseline: Int, peak: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let factor = t <= 0.5 ? (t / 0.5) : ((1.0 - t) / 0.5)
            let value = Double(baseline) + Double(peak - baseline) * factor
            return max(50, Int(value) + Int.random(in: -3...3))
        }
    }
}
