# Apple Health Data Canon

A small iOS developer tool for populating — and cleaning up — synthetic Apple
Health workout data. It fabricates a varied, realistic-looking HealthKit
history so you can develop and test health-related features without waiting to
accumulate real workouts on a physical device.

> [!WARNING]
> This tool writes and **permanently deletes** real HealthKit samples. Run it
> on the iOS Simulator or a dedicated test device — never on your personal
> device. On a physical device, destructive actions stay disabled until you
> explicitly acknowledge that it is a test device.

## What it does

- **Generates sample workouts** — runs, walks, cycles, strength and HIIT
  sessions spread realistically across a configurable number of days, each with
  matching heart-rate, active-energy and distance samples.
- **Cleans up after itself** — deletes every sample the app has written.
  HealthKit only allows an app to delete its *own* data, so data from you or
  other apps is never touched.
- **Never reads your data** — it requests write access only; the read set is
  intentionally empty.

## Configuration

The UI lets you tune generation before running it:

| Setting          | Range        | Default | Notes                                    |
| ---------------- | ------------ | ------- | ---------------------------------------- |
| History          | 1–365 days   | 182     | How far back to spread workouts.         |
| Per day          | 1–4 workouts | 2       | Workouts fabricated for each day.        |

Workouts are distributed between roughly 06:00 and 20:00 with light jitter, and
the generator rotates through the workout kinds so the resulting history looks
varied. Slots that would land in the future are skipped.

## Generated data

Each workout is saved with a `HKWorkoutBuilder` and carries:

- A **heart-rate curve** — a triangular ramp up to a per-kind peak and back down.
- **Active energy burned**, split evenly across the workout duration.
- **Distance** (walking/running or cycling) for distance-based activities;
  strength and HIIT record none.

Per-kind ranges (duration, calories, distance and heart rate) live in
`WorkoutPlanner` in [`WorkoutPlan.swift`](Health%20Data%20Canon/WorkoutPlan.swift).

## Architecture

The code separates *what* to generate from *how* to save it:

- **`WorkoutPlan.swift`** — pure, HealthKit-free models (`WorkoutKind`,
  `WorkoutBlueprint`, `GenerationConfig`) and `WorkoutPlanner`, which turns a
  config into a concrete list of blueprints. All randomness is baked in here, so
  saving is deterministic and the planning logic is easy to read and test.
- **`HealthKitService.swift`** — a thin, `Sendable`, `async`/`await` wrapper
  around HealthKit that requests authorization, saves a blueprint, and
  bulk-deletes app-written data.
- **`HealthDataViewModel.swift`** — `@MainActor` `@Observable` state driving the
  UI. It saves workouts through a bounded concurrent pipeline (up to 12
  `HKWorkoutBuilder`s in flight) to hide per-save IPC latency, tracks progress,
  and keeps a short activity log.
- **`ContentView.swift`** — SwiftUI `Form`-based UI with a loud environment
  banner, authorization status, generation controls, cleanup, and the activity
  log.
- **`AppEnvironment.swift`** — reports whether the build is running on the
  Simulator so the UI can warn (and gate) accordingly.

## Requirements

- Xcode with an iOS 26.0+ deployment target
- The HealthKit capability (already configured in the project entitlements)

## Building & running

1. Open `Health Data Canon.xcodeproj` in Xcode.
2. Select an iOS Simulator (or a dedicated test device).
3. Build and run.
4. Tap **Request HealthKit Access** and grant write permission.
5. Adjust the history and per-day settings, then tap **Generate Sample
   Workouts**.
6. Use **Delete All Generated Data** to wipe everything the app has written.
