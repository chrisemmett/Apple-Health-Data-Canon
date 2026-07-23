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

/// A single GPS fix along a synthetic outdoor route. HealthKit-free on purpose
/// (`CoreLocation`-free too) so route planning stays pure and testable; the
/// service turns these into `CLLocation`s at save time.
struct RoutePoint: Sendable {
    let latitude: Double
    let longitude: Double
    /// Meters above sea level.
    let altitude: Double
    /// Seconds elapsed since the workout start.
    let timeOffset: TimeInterval
    /// Instantaneous ground speed in meters per second.
    let speed: Double
    /// Direction of travel in degrees (0 = north, clockwise). `-1` if unknown.
    let course: Double
    /// Reported horizontal accuracy in meters.
    let horizontalAccuracy: Double
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
    /// A synthetic GPS track for outdoor activities, or `nil` for indoor ones.
    let route: [RoutePoint]?

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
        let duration = TimeInterval(Int.random(in: minutes) * 60)
        let distanceMeters = meters.map { Double(Int.random(in: $0)) }

        // Outdoor, distance-based activities get a synthetic GPS track that
        // wanders through a real London green space and roughly matches the
        // workout's distance and duration. Indoor kinds record no location.
        let route: [RoutePoint]?
        if !kind.isIndoor, let distanceMeters {
            route = LondonRouteGenerator.route(
                distanceMeters: distanceMeters,
                duration: duration
            )
        } else {
            route = nil
        }

        return WorkoutBlueprint(
            kind: kind,
            start: start,
            duration: duration,
            distanceMeters: distanceMeters,
            activeEnergyKilocalories: Double(Int.random(in: kcal)),
            heartRates: heartRateCurve(
                baseline: Int.random(in: hr.baseline),
                peak: Int.random(in: hr.peak),
                count: 10
            ),
            route: route
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

/// A recognisable place in the London region a synthetic route can start from.
struct RouteAnchor: Sendable {
    let name: String
    let latitude: Double
    let longitude: Double
    /// Rough ground elevation in meters, used as the route's altitude baseline.
    let baseAltitude: Double
}

/// Fabricates plausible-looking outdoor GPS tracks around London.
///
/// The route is a *correlated random walk*: each step nudges the previous
/// heading by a small random amount so the path curves like a real one rather
/// than zig-zagging. A gentle, increasing pull back toward the start in the
/// second half turns the track into a loose loop that finishes near where it
/// began — the shape most park runs and rides actually take. Total step length
/// is pinned to the workout's distance, and points are stamped so their speed
/// matches distance ÷ duration.
enum LondonRouteGenerator {

    /// Well-known London green spaces and paths to start from.
    static let anchors: [RouteAnchor] = [
        RouteAnchor(name: "Hyde Park",            latitude: 51.50730, longitude: -0.16570, baseAltitude: 20),
        RouteAnchor(name: "Regent's Park",        latitude: 51.53130, longitude: -0.15700, baseAltitude: 32),
        RouteAnchor(name: "Richmond Park",        latitude: 51.44260, longitude: -0.27520, baseAltitude: 55),
        RouteAnchor(name: "Victoria Park",        latitude: 51.53620, longitude: -0.03960, baseAltitude: 15),
        RouteAnchor(name: "Battersea Park",       latitude: 51.47910, longitude: -0.15670, baseAltitude: 8),
        RouteAnchor(name: "Hampstead Heath",      latitude: 51.56080, longitude: -0.16310, baseAltitude: 98),
        RouteAnchor(name: "Greenwich Park",       latitude: 51.47690, longitude:  0.00050, baseAltitude: 45),
        RouteAnchor(name: "Clapham Common",       latitude: 51.46140, longitude: -0.14850, baseAltitude: 20),
        RouteAnchor(name: "Thames Path, Putney",  latitude: 51.46760, longitude: -0.21600, baseAltitude: 6),
        RouteAnchor(name: "Wimbledon Common",     latitude: 51.43300, longitude: -0.22800, baseAltitude: 50),
    ]

    /// Meters per degree of latitude (near-constant everywhere on Earth).
    private static let metersPerDegreeLatitude = 111_320.0

    /// Builds a synthetic route for a workout of the given distance and duration,
    /// starting from a random London anchor. Returns `nil` for non-positive input.
    static func route(
        distanceMeters: Double,
        duration: TimeInterval,
        sampleInterval: TimeInterval = 5
    ) -> [RoutePoint]? {
        guard distanceMeters > 0, duration > 0,
              let anchor = anchors.randomElement() else { return nil }
        return route(from: anchor, distanceMeters: distanceMeters,
                     duration: duration, sampleInterval: sampleInterval)
    }

    /// Builds a route from a specific anchor. Exposed for deterministic testing.
    static func route(
        from anchor: RouteAnchor,
        distanceMeters: Double,
        duration: TimeInterval,
        sampleInterval: TimeInterval = 5
    ) -> [RoutePoint] {
        // One point every `sampleInterval` seconds, so `steps` legs of travel.
        let steps = max(1, Int((duration / sampleInterval).rounded()))
        let pointCount = steps + 1
        let legLength = distanceMeters / Double(steps)
        let speed = distanceMeters / duration
        let timeStep = duration / Double(steps)

        let metersPerDegreeLongitude =
            metersPerDegreeLatitude * cos(anchor.latitude * .pi / 180)

        var latitude = anchor.latitude
        var longitude = anchor.longitude
        var heading = Double.random(in: 0..<(2 * .pi)) // radians, 0 = north

        var points: [RoutePoint] = []
        points.reserveCapacity(pointCount)
        points.append(point(latitude: latitude, longitude: longitude,
                            anchor: anchor, timeOffset: 0, speed: 0, course: -1))

        for step in 1..<pointCount {
            let progress = Double(step) / Double(steps)

            // Wander: nudge the heading a little each step for a natural curve.
            heading += Double.random(in: -0.35...0.35)

            // Loop home: in the back half, blend the heading toward the bearing
            // back to the start, growing from 0 to ~0.5 so the track closes up.
            if progress > 0.5 {
                let bearingHome = atan2(
                    (anchor.longitude - longitude) * metersPerDegreeLongitude,
                    (anchor.latitude - latitude) * metersPerDegreeLatitude
                )
                let pull = (progress - 0.5) // 0 → 0.5 across the second half
                heading = blendAngle(heading, toward: bearingHome, weight: pull)
            }

            // Advance one leg along the current heading.
            let north = legLength * cos(heading)
            let east = legLength * sin(heading)
            latitude += north / metersPerDegreeLatitude
            longitude += east / metersPerDegreeLongitude

            let courseDegrees = (heading * 180 / .pi)
                .truncatingRemainder(dividingBy: 360)
            let course = courseDegrees < 0 ? courseDegrees + 360 : courseDegrees

            points.append(point(
                latitude: latitude,
                longitude: longitude,
                anchor: anchor,
                timeOffset: timeStep * Double(step),
                speed: max(0, speed + Double.random(in: -0.4...0.4)),
                course: course
            ))
        }

        return points
    }

    private static func point(
        latitude: Double,
        longitude: Double,
        anchor: RouteAnchor,
        timeOffset: TimeInterval,
        speed: Double,
        course: Double
    ) -> RoutePoint {
        RoutePoint(
            latitude: latitude,
            longitude: longitude,
            altitude: anchor.baseAltitude + Double.random(in: -4...4),
            timeOffset: timeOffset,
            speed: speed,
            course: course,
            horizontalAccuracy: Double.random(in: 3...8)
        )
    }

    /// Blends `angle` toward `target` (both radians) by `weight` in [0, 1],
    /// taking the shortest way around the circle.
    private static func blendAngle(_ angle: Double, toward target: Double, weight: Double) -> Double {
        var delta = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return angle + delta * min(max(weight, 0), 1)
    }
}
