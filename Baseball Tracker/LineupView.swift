//
//  LineupView.swift
//  Baseball Tracker
//
//  Two-tab sheet: Roster management and the live at-bat pitch tracker.
//  The at-bat tracker shows a Gameday-style strike zone map of every pitch
//  in the current at-bat, colour-coded by outcome.
//

import SwiftUI

// MARK: - Root sheet

struct LineupView: View {
    @ObservedObject var store: LineupStore
    @ObservedObject var settings: CameraSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 1
    @State private var showingAddPlayer = false

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                AtBatTrackerView(store: store, settings: settings)
                    .tabItem { Label("At Bat", systemImage: "baseball") }
                    .tag(0)

                RosterView(store: store, showingAddPlayer: $showingAddPlayer)
                    .tabItem { Label("Roster", systemImage: "person.3") }
                    .tag(1)
            }
            .navigationTitle(selectedTab == 0 ? "At Bat Tracker" : "Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectedTab == 1 {
                        Button { showingAddPlayer = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - At-Bat Tracker Tab

struct AtBatTrackerView: View {
    @ObservedObject var store: LineupStore
    @ObservedObject var settings: CameraSettings

    @State private var showingOutcomePicker = false
    @State private var pendingMarkers: [CGPoint] = []
    @State private var showingCompleteAB = false
    @State private var showingNewAB = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Active batter selector
                BatterSelectorCard(store: store)
                    .padding(.horizontal)

                if let batter = store.activeBatter {
                    // Current count chip
                    if let ab = store.activeAtBat {
                        CountChip(atBat: ab)
                    }

                    // Strike zone map for current AB
                    if let ab = store.activeAtBat, !ab.pitches.isEmpty {
                        PitchZoneMapCard(atBat: ab, settings: settings, batter: batter)
                            .padding(.horizontal)
                    } else {
                        Text("No pitches yet in this at-bat")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }

                    // AB action buttons
                    HStack(spacing: 12) {
                        Button {
                            showingNewAB = true
                        } label: {
                            Label("New AB", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .confirmationDialog("Start new at-bat for \(batter.name)?",
                                            isPresented: $showingNewAB,
                                            titleVisibility: .visible) {
                            Button("Start New At-Bat") { store.startNewAtBat() }
                            Button("Cancel", role: .cancel) {}
                        }

                        if store.activeAtBat != nil {
                            Button {
                                showingCompleteAB = true
                            } label: {
                                Label("End AB", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .confirmationDialog("Result of this at-bat?",
                                                isPresented: $showingCompleteAB,
                                                titleVisibility: .visible) {
                                ForEach(AtBatResult.allCases.filter { $0.isComplete }, id: \.self) { result in
                                    Button(result.rawValue) { store.completeAtBat(result: result) }
                                }
                                Button("Cancel", role: .cancel) {}
                            }
                        }
                    }
                    .padding(.horizontal)

                    // Previous ABs for this batter
                    let history = store.atBats(for: batter).filter { $0.result.isComplete }
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Previous At-Bats")
                                .font(.headline)
                                .padding(.horizontal)
                            ForEach(history) { ab in
                                PreviousABRow(ab: ab, settings: settings, batter: batter)
                                    .padding(.horizontal)
                            }
                        }
                    }

                } else {
                    ContentUnavailableView(
                        "No Batter Selected",
                        systemImage: "person.slash",
                        description: Text("Select a batter in the Roster tab or tap the selector above.")
                    )
                    .padding(.top, 32)
                }
            }
            .padding(.vertical)
        }
    }
}

// MARK: - Batter Selector Card

struct BatterSelectorCard: View {
    @ObservedObject var store: LineupStore
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Batter")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let batter = store.activeBatter {
                        HStack(spacing: 6) {
                            Text(batter.name)
                                .font(.headline)
                            HandednessTag(handedness: batter.handedness)
                        }
                    } else {
                        Text("Tap to select")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .confirmationDialog("Select Active Batter", isPresented: $showPicker, titleVisibility: .visible) {
            ForEach(store.players.indices, id: \.self) { i in
                Button(store.players[i].name) {
                    store.activeBatterIndex = i
                    // Auto-start an AB if none is active
                    if store.activeAtBat == nil { store.startNewAtBat() }
                }
            }
            Button("None (clear)", role: .destructive) { store.activeBatterIndex = nil }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Count chip

struct CountChip: View {
    let atBat: AtBat

    var body: some View {
        HStack(spacing: 16) {
            VStack {
                Text("\(atBat.balls)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                Text("Balls").font(.caption2).foregroundColor(.secondary)
            }
            Text("-")
                .font(.title2)
                .foregroundColor(.secondary)
            VStack {
                Text("\(atBat.strikes)")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.red)
                Text("Strikes").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Text("Pitch \(atBat.pitches.count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
    }
}

// MARK: - Pitch Zone Map Card

/// Gameday-style top-down view of the strike zone with dots for each pitch.
/// Dots are coloured by outcome. Pitch number is shown inside each dot.
struct PitchZoneMapCard: View {
    let atBat: AtBat
    let settings: CameraSettings
    let batter: Player

    // Strike zone dimensions in Vision-normalised space.
    // We convert world-inch offsets to approximate normalised positions
    // using the plate calibration when available; otherwise use defaults.
    private var zoneBottomNorm: Double {
        // strikeZoneBottomOffset inches above plate, converted using normPerInch.
        // Without calibration we fall back to a fixed fraction of the frame.
        settings.isCalibrated ? calibratedZoneBottomNorm : 0.35
    }
    private var zoneTopNorm: Double {
        settings.isCalibrated ? calibratedZoneTopNorm : 0.65
    }
    private var zoneLeftNorm: Double {
        settings.isCalibrated ? Double(settings.platePoints[HomePlatePoint.left.rawValue].x) : 0.35
    }
    private var zoneRightNorm: Double {
        settings.isCalibrated ? Double(settings.platePoints[HomePlatePoint.right.rawValue].x) : 0.65
    }

    private var normPerInch: Double {
        guard settings.isCalibrated else { return 0.012 }
        let left  = settings.platePoints[HomePlatePoint.left.rawValue]
        let right = settings.platePoints[HomePlatePoint.right.rawValue]
        let dx = right.x - left.x
        let dy = right.y - left.y
        let normWidth = sqrt(dx*dx + dy*dy)
        return Double(normWidth) / settings.plateWidth
    }

    private var calibratedZoneBottomNorm: Double {
        // Anchor = average UIKit Y of left/right mid-edge points, converted to Vision Y.
        // Zone bottom is bottomOffset inches above that anchor (moving up = lower UIKit Y = higher Vision Y).
        let left  = settings.platePoints[HomePlatePoint.left.rawValue]
        let right = settings.platePoints[HomePlatePoint.right.rawValue]
        let anchorUIKitY = Double((left.y + right.y) / 2)
        let anchorVisionY = 1.0 - anchorUIKitY
        return anchorVisionY + normPerInch * settings.strikeZoneBottomOffset
    }

    private var calibratedZoneTopNorm: Double {
        calibratedZoneBottomNorm + normPerInch * settings.strikeZoneHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Strike Zone — \(atBat.pitches.count) pitch\(atBat.pitches.count == 1 ? "" : "es")")
                .font(.subheadline.weight(.semibold))

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    // Background
                    Color(.systemBackground)

                    // Full frame boundary (faint)
                    Rectangle()
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)

                    // Strike zone rectangle
                    let zl = CGFloat(zoneLeftNorm)  * w
                    let zr = CGFloat(zoneRightNorm) * w
                    let zb = (1 - CGFloat(zoneBottomNorm)) * h
                    let zt = (1 - CGFloat(zoneTopNorm))    * h

                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: zr - zl, height: zb - zt)
                        .position(x: (zl + zr) / 2, y: (zt + zb) / 2)

                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
                        .frame(width: zr - zl, height: zb - zt)
                        .position(x: (zl + zr) / 2, y: (zt + zb) / 2)

                    // Pitch dots
                    ForEach(atBat.pitches) { pitch in
                        if let last = pitch.markers.last {
                            // Vision Y: 0=bottom, 1=top → flip for UIKit display
                            let px = CGFloat(last.x) * w
                            let py = (1 - CGFloat(last.y)) * h
                            PitchDot(pitch: pitch, position: CGPoint(x: px, y: py))
                        }
                    }
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))

            // Legend
            outcomeKeyView
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var outcomeKeyView: some View {
        let used = Set(atBat.pitches.map { $0.outcome })
        return HStack(spacing: 12) {
            ForEach(PitchOutcome.allCases.filter { used.contains($0) }, id: \.self) { outcome in
                HStack(spacing: 4) {
                    Circle().fill(outcome.color).frame(width: 10, height: 10)
                    Text(outcome.rawValue).font(.caption2)
                }
            }
        }
    }
}

struct PitchDot: View {
    let pitch: Pitch
    let position: CGPoint

    var body: some View {
        ZStack {
            Circle()
                .fill(pitch.outcome.color)
                .frame(width: 22, height: 22)
                .shadow(radius: 2)
            Text("\(pitch.pitchNumber)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
        }
        .position(position)
    }
}

// MARK: - Previous AB Row

struct PreviousABRow: View {
    let ab: AtBat
    let settings: CameraSettings
    let batter: Player
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ab.result.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Text("\(ab.pitches.count) pitch\(ab.pitches.count == 1 ? "" : "es") • \(ab.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    // Mini pitch sequence
                    HStack(spacing: 3) {
                        ForEach(ab.pitches.prefix(8)) { pitch in
                            Circle()
                                .fill(pitch.outcome.color)
                                .frame(width: 8, height: 8)
                        }
                        if ab.pitches.count > 8 {
                            Text("+\(ab.pitches.count - 8)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(.plain)

            if expanded && !ab.pitches.isEmpty {
                PitchZoneMapCard(atBat: ab, settings: settings, batter: batter)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Roster Tab

struct RosterView: View {
    @ObservedObject var store: LineupStore
    @Binding var showingAddPlayer: Bool
    @State private var editingPlayer: Player? = nil

    var body: some View {
        List {
            if store.players.isEmpty {
                ContentUnavailableView(
                    "No Players",
                    systemImage: "person.badge.plus",
                    description: Text("Tap + to add players to your lineup.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.players.indices, id: \.self) { i in
                    PlayerRow(player: store.players[i],
                               isActive: store.activeBatterIndex == i) {
                        editingPlayer = store.players[i]
                    }
                }
                .onDelete { store.removePlayer(at: $0) }
            }
        }
        .sheet(isPresented: $showingAddPlayer) {
            PlayerEditView(store: store, player: nil)
        }
        .sheet(item: $editingPlayer) { player in
            PlayerEditView(store: store, player: player)
        }
    }
}

struct PlayerRow: View {
    let player: Player
    let isActive: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isActive {
                Image(systemName: "baseball.fill")
                    .foregroundColor(.yellow)
                    .frame(width: 20)
            } else {
                Spacer().frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(player.name).font(.body.weight(.medium))
                    HandednessTag(handedness: player.handedness)
                }
                Text(String(format: "%.0f\" (%.0f\" zone)", player.heightInches, player.strikeZoneHeight))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(isActive ? Color.yellow.opacity(0.08) : Color.clear)
    }
}

// MARK: - Handedness tag

struct HandednessTag: View {
    let handedness: Handedness
    var body: some View {
        Text(handedness.rawValue)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(handedness == .left ? Color.blue.opacity(0.2) :
                        handedness == .right ? Color.red.opacity(0.2) :
                        Color.purple.opacity(0.2))
            .foregroundColor(handedness == .left ? .blue :
                             handedness == .right ? .red : .purple)
            .clipShape(Capsule())
    }
}

// MARK: - Player Add/Edit Sheet

struct PlayerEditView: View {
    @ObservedObject var store: LineupStore
    let player: Player?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var handedness: Handedness = .right
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 10

    private var totalHeightInches: Double { Double(heightFeet * 12 + heightInches) }
    private var isEditing: Bool { player != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Player Info") {
                    TextField("Name", text: $name)
                    Picker("Bats", selection: $handedness) {
                        ForEach(Handedness.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Height") {
                    HStack {
                        Picker("Feet", selection: $heightFeet) {
                            ForEach(4...7, id: \.self) { Text("\($0) ft").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)

                        Picker("Inches", selection: $heightInches) {
                            ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 100)
                }

                Section("Personalised Strike Zone") {
                    let p = Player(name: name, handedness: handedness, heightInches: totalHeightInches)
                    LabeledContent("Bottom offset", value: String(format: "%.1f\"", p.strikeZoneBottom))
                    LabeledContent("Zone height",   value: String(format: "%.1f\"", p.strikeZoneHeight))
                    LabeledContent("Zone top",      value: String(format: "%.1f\"", p.strikeZoneBottom + p.strikeZoneHeight))
                }
            }
            .navigationTitle(isEditing ? "Edit Player" : "Add Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        var p = Player(name: name, handedness: handedness, heightInches: totalHeightInches)
                        if let existing = player {
                            p.id = existing.id
                            store.updatePlayer(p)
                        } else {
                            store.addPlayer(p)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let p = player {
                    name        = p.name
                    handedness  = p.handedness
                    heightFeet  = Int(p.heightInches) / 12
                    heightInches = Int(p.heightInches) % 12
                }
            }
        }
    }
}

// MARK: - Pitch outcome selector sheet (called from ContentView after processing)

struct PitchOutcomeSheet: View {
    let markers: [CGPoint]
    let onConfirm: (PitchOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("What was the result of this pitch?") {
                    ForEach(PitchOutcome.allCases, id: \.self) { outcome in
                        Button {
                            onConfirm(outcome)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(outcome.color)
                                    .frame(width: 14, height: 14)
                                Text(outcome.rawValue)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pitch Outcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
