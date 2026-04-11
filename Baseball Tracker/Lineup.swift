//
//  Lineup.swift
//  Baseball Tracker
//
//  Data model for the player lineup and at-bat pitch tracker.
//
//  Persistence: LineupStore encodes itself to JSON and saves to UserDefaults
//  on every mutation so data survives app restarts.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Player

enum Handedness: String, Codable, CaseIterable {
    case right  = "R"
    case left   = "L"
    case both   = "S"   // Switch hitter

    var label: String {
        switch self {
        case .right: return "Right"
        case .left:  return "Left"
        case .both:  return "Switch"
        }
    }
}

struct Player: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var handedness: Handedness
    /// Height in inches.
    var heightInches: Double

    // MARK: MLB-formula personalised strike zone
    // Bottom of zone  ≈ hollow of knee  ≈ height × 0.27
    // Top of zone     ≈ midpoint belt/shoulders ≈ height × 0.535
    // Both relative to ground; the app stores them as distance *above plate*.
    // The plate surface is ~0 inches (ground level).

    /// Distance from the ground to the bottom of the strike zone (inches).
    var strikeZoneBottom: Double { heightInches * 0.27 }
    /// Height of the strike zone (inches).
    var strikeZoneHeight: Double { (heightInches * 0.535) - strikeZoneBottom }
}

// MARK: - Pitch outcome

enum PitchOutcome: String, Codable, CaseIterable {
    case ball        = "Ball"
    case calledStrike = "Called Strike"
    case swingMiss   = "Swing & Miss"
    case foul        = "Foul"
    case inPlay      = "In Play"

    var color: Color {
        switch self {
        case .ball:         return .green
        case .calledStrike: return .red
        case .swingMiss:    return .orange
        case .foul:         return .yellow
        case .inPlay:       return .blue
        }
    }

    var shortLabel: String {
        switch self {
        case .ball:         return "B"
        case .calledStrike: return "K"
        case .swingMiss:    return "S"
        case .foul:         return "F"
        case .inPlay:       return "X"
        }
    }
}

// MARK: - Pitch

struct Pitch: Identifiable, Codable {
    var id: UUID = UUID()
    /// Ball-detection markers in Vision-normalised coords (X: 0–1 left-right, Y: 0–1 bottom-top).
    var markers: [CGPoint]
    var outcome: PitchOutcome
    var timestamp: Date = Date()
    /// 1-based pitch number within the at-bat.
    var pitchNumber: Int

    // CGPoint isn't directly Codable; we bridge via CodablePoint.
    enum CodingKeys: String, CodingKey {
        case id, markersX, markersY, outcome, timestamp, pitchNumber
    }

    init(id: UUID = UUID(), markers: [CGPoint], outcome: PitchOutcome,
         timestamp: Date = Date(), pitchNumber: Int) {
        self.id = id
        self.markers = markers
        self.outcome = outcome
        self.timestamp = timestamp
        self.pitchNumber = pitchNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self,          forKey: .id)
        outcome     = try c.decode(PitchOutcome.self,  forKey: .outcome)
        timestamp   = try c.decode(Date.self,          forKey: .timestamp)
        pitchNumber = try c.decode(Int.self,           forKey: .pitchNumber)
        let xs      = try c.decode([Double].self,      forKey: .markersX)
        let ys      = try c.decode([Double].self,      forKey: .markersY)
        markers     = zip(xs, ys).map { CGPoint(x: $0, y: $1) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,          forKey: .id)
        try c.encode(outcome,     forKey: .outcome)
        try c.encode(timestamp,   forKey: .timestamp)
        try c.encode(pitchNumber, forKey: .pitchNumber)
        try c.encode(markers.map { $0.x }, forKey: .markersX)
        try c.encode(markers.map { $0.y }, forKey: .markersY)
    }
}

// MARK: - At-Bat result

enum AtBatResult: String, Codable, CaseIterable {
    case active     = "Active"
    case strikeout  = "Strikeout"
    case walk       = "Walk"
    case hitByPitch = "HBP"
    case single     = "Single"
    case double_    = "Double"
    case triple     = "Triple"
    case homeRun    = "Home Run"
    case out        = "Out"

    var isComplete: Bool { self != .active }
}

// MARK: - At-Bat

struct AtBat: Identifiable, Codable {
    var id: UUID = UUID()
    var playerID: UUID
    var pitches: [Pitch] = []
    var result: AtBatResult = .active
    var date: Date = Date()

    var balls:   Int { pitches.filter { $0.outcome == .ball }.count }
    var strikes: Int {
        pitches.filter {
            $0.outcome == .calledStrike || $0.outcome == .swingMiss ||
            ($0.outcome == .foul && currentStrikes < 2)
        }.count
    }

    /// Running strike count (foul balls can't raise strikes past 2).
    private var currentStrikes: Int {
        var s = 0
        for p in pitches {
            if p.outcome == .calledStrike || p.outcome == .swingMiss { s += 1 }
            else if p.outcome == .foul && s < 2 { s += 1 }
        }
        return s
    }

    var count: String { "\(balls)-\(currentStrikes)" }
}

// MARK: - LineupStore

/// Observable store for the active lineup. Persists to UserDefaults as JSON.
final class LineupStore: ObservableObject {

    private static let playersKey = "lineup.players"
    private static let atBatsKey  = "lineup.atBats"
    private static let activeKey  = "lineup.activeBatterIndex"

    @Published var players: [Player] = [] {
        didSet { save() }
    }

    @Published var atBats: [AtBat] = [] {
        didSet { save() }
    }

    /// Index into `players` for the current batter. nil = no batter selected.
    @Published var activeBatterIndex: Int? = nil {
        didSet { save() }
    }

    var activeBatter: Player? {
        guard let i = activeBatterIndex, players.indices.contains(i) else { return nil }
        return players[i]
    }

    /// The currently active (incomplete) at-bat for the active batter, if any.
    var activeAtBat: AtBat? {
        guard let batter = activeBatter else { return nil }
        return atBats.last { $0.playerID == batter.id && !$0.result.isComplete }
    }

    init() { load() }

    // MARK: - Roster management

    func addPlayer(_ player: Player) {
        players.append(player)
    }

    func updatePlayer(_ player: Player) {
        guard let i = players.firstIndex(where: { $0.id == player.id }) else { return }
        players[i] = player
    }

    func removePlayer(at offsets: IndexSet) {
        // Remove any at-bats belonging to deleted players
        let removedIDs = offsets.map { players[$0].id }
        atBats.removeAll { removedIDs.contains($0.playerID) }
        players.remove(atOffsets: offsets)
        // Reset active index if it pointed at a removed player
        if let i = activeBatterIndex {
            if offsets.contains(i) { activeBatterIndex = nil }
            else if i >= players.count { activeBatterIndex = players.isEmpty ? nil : players.count - 1 }
        }
    }

    /// Apply a roster received from the host device over the peer session.
    /// Merges by UUID: adds new players, updates existing ones, removes absent ones.
    /// The active batter index is reset if their player was removed.
    func applyRemotePlayers(_ remotePlayers: [Player]) {
        let remoteIDs = Set(remotePlayers.map { $0.id })

        // Update existing and add new
        for remote in remotePlayers {
            if let i = players.firstIndex(where: { $0.id == remote.id }) {
                players[i] = remote
            } else {
                players.append(remote)
            }
        }

        // Remove players that the host has deleted
        let removedIDs = players.filter { !remoteIDs.contains($0.id) }.map { $0.id }
        if !removedIDs.isEmpty {
            atBats.removeAll { removedIDs.contains($0.playerID) }
            players.removeAll { removedIDs.contains($0.id) }
            if let i = activeBatterIndex, !players.indices.contains(i) {
                activeBatterIndex = nil
            }
        }

        print("[Roster] Applied remote roster: \(players.count) players")
    }

    // MARK: - At-bat management

    /// Start a new at-bat for the active batter (ends any open one first).
    func startNewAtBat() {
        guard let batter = activeBatter else { return }
        // Complete any open AB for this batter
        if let idx = atBats.indices.last(where: { atBats[$0].playerID == batter.id && !atBats[$0].result.isComplete }) {
            atBats[idx].result = .out
        }
        atBats.append(AtBat(playerID: batter.id))
    }

    /// Record a pitch result into the active at-bat. Creates a new AB if none exists.
    func recordPitch(markers: [CGPoint], outcome: PitchOutcome) {
        guard activeBatter != nil else { return }
        if activeAtBat == nil { startNewAtBat() }
        guard let idx = atBats.indices.last(where: { !atBats[$0].result.isComplete }) else { return }
        let pitchNum = atBats[idx].pitches.count + 1
        atBats[idx].pitches.append(Pitch(markers: markers, outcome: outcome, pitchNumber: pitchNum))
    }

    /// Close the active at-bat with a final result.
    func completeAtBat(result: AtBatResult) {
        guard let idx = atBats.indices.last(where: { !atBats[$0].result.isComplete }) else { return }
        atBats[idx].result = result
    }

    /// All at-bats for a given player, newest first.
    func atBats(for player: Player) -> [AtBat] {
        atBats.filter { $0.playerID == player.id }.reversed()
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(players) {
            UserDefaults.standard.set(data, forKey: Self.playersKey)
        }
        if let data = try? encoder.encode(atBats) {
            UserDefaults.standard.set(data, forKey: Self.atBatsKey)
        }
        UserDefaults.standard.set(activeBatterIndex, forKey: Self.activeKey)
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.playersKey),
           let decoded = try? decoder.decode([Player].self, from: data) {
            players = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.atBatsKey),
           let decoded = try? decoder.decode([AtBat].self, from: data) {
            atBats = decoded
        }
        activeBatterIndex = UserDefaults.standard.object(forKey: Self.activeKey) as? Int
    }
}
