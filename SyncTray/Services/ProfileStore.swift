import Foundation
import Combine

/// Manages the storage and retrieval of sync profiles
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [SyncProfile] = []
    @Published var selectedProfileId: UUID?

    private static let profilesKey = "syncProfiles"
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    // MARK: - Persistence

    /// Load profiles from UserDefaults
    func load() {
        guard let data = defaults.data(forKey: Self.profilesKey) else {
            profiles = []
            return
        }

        do {
            profiles = try JSONDecoder().decode([SyncProfile].self, from: data)
        } catch {
            print("Failed to decode profiles: \(error)")
            profiles = []
        }
    }

    /// Save profiles to UserDefaults
    func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            defaults.set(data, forKey: Self.profilesKey)
        } catch {
            print("Failed to encode profiles: \(error)")
        }
    }

    // MARK: - CRUD Operations

    /// Add a new profile
    func add(_ profile: SyncProfile) {
        profiles.append(profile)
        save()
    }

    /// Update an existing profile
    func update(_ profile: SyncProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        profiles[index] = profile
        save()
    }

    /// Delete a profile by ID
    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        save()
    }

    /// Get a profile by ID
    func profile(for id: UUID) -> SyncProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Convenience

    /// Selected profile based on selectedProfileId
    var selectedProfile: SyncProfile? {
        get {
            guard let id = selectedProfileId else { return nil }
            return profile(for: id)
        }
        set {
            selectedProfileId = newValue?.id
            if let profile = newValue {
                update(profile)
            }
        }
    }

    /// All enabled profiles
    var enabledProfiles: [SyncProfile] {
        profiles.filter { $0.isEnabled }
    }

    /// Create a new profile and add it to the store
    @discardableResult
    func createNewProfile() -> SyncProfile {
        let profile = SyncProfile.newProfile()
        add(profile)
        selectedProfileId = profile.id
        return profile
    }
}
