//
//  ProfileStoreTests.swift
//  Tests for the profile file: persistence across store instances, tolerance of a
//  missing, corrupt or foreign-version file, and the ControlID ⇄ string key mapping.
//

import Foundation
import Testing

/// A fresh, empty directory per test, so stores never share a `profiles.json`.
private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
}

private func writeFile(_ text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appendingPathComponent("profiles.json"))
}

private let key = "413c-c015-SN123"
private let profile = Profile(snapshot: [.brightness: -5, .whiteBalanceAuto: 1], reapplyOnConnect: true)

struct ProfileStoreTests {
    // MARK: - Persistence

    @Test func missingFileReadsAsNoProfiles() {
        let store = ProfileStore(directory: temporaryDirectory())
        #expect(store.profile(for: key) == nil)
    }

    @Test func upsertPersistsAcrossInstances() {
        let dir = temporaryDirectory()
        ProfileStore(directory: dir).upsert(profile, for: key)
        #expect(ProfileStore(directory: dir).profile(for: key) == profile)
    }

    @Test func upsertReplacesExistingProfile() {
        let dir = temporaryDirectory()
        let store = ProfileStore(directory: dir)
        store.upsert(profile, for: key)
        let updated = Profile(snapshot: [.zoom: 200], reapplyOnConnect: false)
        store.upsert(updated, for: key)
        #expect(store.profile(for: key) == updated)
        #expect(ProfileStore(directory: dir).profile(for: key) == updated)
    }

    @Test func deleteRemovesOnlyThatProfile() {
        let dir = temporaryDirectory()
        let store = ProfileStore(directory: dir)
        store.upsert(profile, for: key)
        store.upsert(profile, for: "other")
        store.delete(for: key)
        let reloaded = ProfileStore(directory: dir)
        #expect(reloaded.profile(for: key) == nil)
        #expect(reloaded.profile(for: "other") == profile)
    }

    // MARK: - Unreadable files

    @Test func corruptFileReadsAsNoProfiles() throws {
        let dir = temporaryDirectory()
        try writeFile("{ not json", in: dir)
        #expect(ProfileStore(directory: dir).profile(for: key) == nil)
    }

    @Test func unsupportedVersionReadsAsNoProfiles() throws {
        let dir = temporaryDirectory()
        try writeFile("""
            {"version": 2, "profiles": {"\(key)": {"snapshot": {"brightness": 1}, "reapplyOnConnect": true}}}
            """, in: dir)
        #expect(ProfileStore(directory: dir).profile(for: key) == nil)
    }

    @Test func readsVersionOneFile() throws {
        let dir = temporaryDirectory()
        try writeFile("""
            {"version": 1, "profiles": {"\(key)": {"snapshot": {"brightness": -5}, "reapplyOnConnect": true}}}
            """, in: dir)
        let loaded = ProfileStore(directory: dir).profile(for: key)
        #expect(loaded?.decodedSnapshot == [.brightness: -5])
        #expect(loaded?.reapplyOnConnect == true)
    }

    // MARK: - Snapshot keys

    @Test func snapshotIsStoredUnderRawValues() {
        #expect(profile.snapshot == ["brightness": -5, "whiteBalanceAuto": 1])
    }

    @Test func decodedSnapshotRoundTrips() {
        #expect(profile.decodedSnapshot == [.brightness: -5, .whiteBalanceAuto: 1])
    }

    @Test func decodedSnapshotDropsUnknownKeys() {
        let p = Profile(snapshot: ["brightness": 3, "focus": 40], reapplyOnConnect: false)
        #expect(p.decodedSnapshot == [.brightness: 3])
    }
}
