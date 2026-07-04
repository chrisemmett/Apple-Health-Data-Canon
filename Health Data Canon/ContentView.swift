//
//  ContentView.swift
//  Health Data Canon
//
//  Developer utility for populating / wiping synthetic HealthKit workout data.
//  The UI is deliberately loud about the fact that this tool mutates *real*
//  HealthKit storage and is meant for the Simulator or a dedicated test device.
//

import SwiftUI

struct ContentView: View {
    @State private var model = HealthDataViewModel()
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                EnvironmentBanner(
                    isSimulator: AppEnvironment.isSimulator,
                    acknowledged: $model.acknowledgedDeviceRisk
                )

                if !model.isHealthDataAvailable {
                    unavailableSection
                }

                authorizationSection
                generateSection
                cleanupSection
                activityLogSection
            }
            .navigationTitle("Health Data Canon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label("Developer Tool", systemImage: "hammer.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Sections

    private var unavailableSection: some View {
        Section {
            Label("HealthKit is not available on this device.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var authorizationSection: some View {
        Section {
            LabeledContent("Status") {
                AuthorizationBadge(state: model.authorization)
            }
            Button {
                Task { await model.requestAuthorization() }
            } label: {
                Label("Request HealthKit Access", systemImage: "heart.text.square")
            }
            .disabled(!model.isHealthDataAvailable || model.isBusy)
        } header: {
            Text("Authorization")
        } footer: {
            Text("Grants write access for workouts, heart rate, active energy and distance. This tool never reads your data.")
        }
    }

    private var generateSection: some View {
        Section {
            Stepper(value: $model.config.days, in: 1...365, step: 1) {
                LabeledContent("History", value: "\(model.config.days) days")
            }
            Stepper(value: $model.config.workoutsPerDay, in: 1...4) {
                LabeledContent("Per day", value: "\(model.config.workoutsPerDay)×")
            }
            LabeledContent("Total workouts") {
                Text("\(model.config.totalWorkouts)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let progress = model.progress {
                ProgressView(value: progress.fraction) {
                    Text("Generating…")
                } currentValueLabel: {
                    Text("\(progress.completed) / \(progress.total)")
                        .monospacedDigit()
                }
            }

            Button {
                Task { await model.generate() }
            } label: {
                Label("Generate Sample Workouts", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.actionsEnabled)
        } header: {
            Text("Generate Sample Data")
        } footer: {
            Text("Creates a varied history of synthetic workouts — runs, walks, cycles, strength and HIIT — with matching heart-rate, energy and distance samples.")
        }
    }

    private var cleanupSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete All Generated Data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.actionsEnabled)
            .confirmationDialog(
                "Delete every sample written by this app?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    Task { await model.deleteAllGeneratedData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all workouts, heart-rate, energy and distance samples that Health Data Canon has written. HealthKit only allows deleting this app's own data.")
            }
        } header: {
            Text("Clean Up")
        } footer: {
            Text("Only samples written by this app are affected — data from you or other apps is never touched.")
        }
    }

    private var activityLogSection: some View {
        Section {
            if model.log.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.log) { entry in
                    LogRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("Activity Log")
                Spacer()
                if !model.log.isEmpty {
                    Button("Clear") { model.clearLog() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }
}

// MARK: - Components

/// Loud, always-visible banner describing the run destination and, on a real
/// device, gating destructive actions behind an explicit acknowledgement.
private struct EnvironmentBanner: View {
    let isSimulator: Bool
    @Binding var acknowledged: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(isSimulator ? "Developer Tool — Simulator" : "Running on a Physical Device")
                        .font(.headline)
                } icon: {
                    Image(systemName: isSimulator ? "hammer.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(isSimulator ? Color.primary : Color.white)

                Text(isSimulator
                     ? "This tool writes and deletes real HealthKit samples. Keep it on the Simulator or a dedicated test device — never a personal one."
                     : "This build is meant for the Simulator or a dedicated test device. It will write and permanently delete real Health data. Do not use your personal device.")
                    .font(.footnote)
                    .foregroundStyle(isSimulator ? Color.secondary : Color.white.opacity(0.9))

                if !isSimulator {
                    Toggle(isOn: $acknowledged) {
                        Text("I understand — this is a dedicated test device")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .tint(.white)
                    .toggleStyle(.switch)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(isSimulator ? Color.yellow.opacity(0.18) : Color.red)
    }
}

private struct AuthorizationBadge: View {
    let state: HealthDataViewModel.AuthorizationState

    private var color: Color {
        switch state {
        case .unknown: .secondary
        case .authorized: .green
        case .denied: .orange
        }
    }

    var body: some View {
        Label(state.label, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
            .imageScale(.small)
            .foregroundStyle(color)
    }
}

private struct LogRow: View {
    let entry: HealthDataViewModel.LogEntry

    private var icon: (name: String, color: Color) {
        switch entry.level {
        case .info: ("info.circle", .secondary)
        case .success: ("checkmark.circle.fill", .green)
        case .failure: ("exclamationmark.circle.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.subheadline)
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

#Preview {
    ContentView()
}
