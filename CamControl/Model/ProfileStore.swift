//
//  ProfileStore.swift
//  Persists per-camera profiles to one JSON file, keyed by `USBDevice.persistenceKey`
//  (`vendor-product-serial`, port-independent — ADR-0002).
//
//  A profile is `{ snapshot, reapplyOnConnect }`. The whole map is loaded once
//  at construction and held in memory; mutations rewrite the file atomically. I/O is
//  best-effort and silent: a missing/corrupt file reads as "no profiles",
//  a failed write is logged and swallowed — no error ever reaches the UI.
//

import Foundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "ProfileStore")

/// One camera's persisted profile. `snapshot` maps `ControlID.rawValue` → native value
/// (only currently-supported controls; White Balance contributes both Auto and Temp).
struct Profile: Codable, Equatable {
    var snapshot: [String: Int64]
    var reapplyOnConnect: Bool
}

/// The JSON boundary: `ControlID`-keyed snapshots ⇄ the `rawValue`-keyed on-disk form.
extension Profile {
    init(snapshot: [ControlID: Int64], reapplyOnConnect: Bool) {
        self.init(
            snapshot: Dictionary(uniqueKeysWithValues: snapshot.map { ($0.key.rawValue, $0.value) }),
            reapplyOnConnect: reapplyOnConnect)
    }

    /// The snapshot with its keys decoded back to `ControlID`s; unknown keys (from a
    /// newer schema or hand-edited file) are dropped.
    var decodedSnapshot: [ControlID: Int64] {
        Dictionary(uniqueKeysWithValues: snapshot.compactMap { key, value in
            ControlID(rawValue: key).map { ($0, value) }
        })
    }
}

/// Loads/saves all profiles from a single `profiles.json`. Synchronous, main-actor: the
/// file is a handful of tiny profiles, so blocking writes are imperceptible and avoid any
/// async partial-write races. One instance lives at app scope, shared by `AppModel` and
/// `ReapplyService` — the whole map is cached in memory, so two instances would go stale
/// against each other.
final class ProfileStore {
    /// Top-level file shape: a schema `version` plus the `uniqueID`-keyed profile map.
    private struct Container: Codable {
        var version: Int
        var profiles: [String: Profile]
    }

    private static let currentVersion = 1

    private let url: URL
    private var profiles: [String: Profile]

    /// `directory` is injectable for tests; production uses Application Support/CamControl.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamControl", isDirectory: true)
        self.url = dir.appendingPathComponent("profiles.json")
        self.profiles = Self.load(from: url)
    }

    private static func load(from url: URL) -> [String: Profile] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let container = try JSONDecoder().decode(Container.self, from: data)
            guard container.version == currentVersion else {
                log.notice("profiles.json version \(container.version, privacy: .public) unsupported; ignoring")
                return [:]
            }
            return container.profiles
        } catch {
            log.error("decode profiles.json failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    // MARK: - Access

    func profile(for key: String) -> Profile? { profiles[key] }

    func upsert(_ profile: Profile, for key: String) {
        profiles[key] = profile
        persist()
    }

    func delete(for key: String) {
        profiles.removeValue(forKey: key)
        persist()
    }

    private func persist() {
        let container = Container(version: Self.currentVersion, profiles: profiles)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(container).write(to: url, options: .atomic)
        } catch {
            log.error("write profiles.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
