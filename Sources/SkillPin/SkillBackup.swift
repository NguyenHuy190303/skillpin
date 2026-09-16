import Foundation

struct SkillBackup: Sendable {
    struct Entry: Codable, Identifiable, Sendable {
        let id: String
        let name: String
        let originalPath: String
        let providerKey: String
        let createdAt: Date
        let linkTarget: String?
    }

    enum Failure: LocalizedError {
        case protected, missing, conflict, dependents, invalidBackup
        var errorDescription: String? {
            switch self {
            case .protected: "Only standalone user skills can be archived. Manage plugin skills through their plugin."
            case .missing: "The source no longer exists. Refresh before trying again."
            case .conflict: "The original location is occupied. Nothing was overwritten."
            case .dependents: "Other pins link to this folder. Disable those links first; moving this folder would break them."
            case .invalidBackup: "The backup record or its destination is invalid. Nothing was moved."
            }
        }
    }

    let root: URL
    static var `default`: SkillBackup {
        .init(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: "skills-backup"))
    }

    func entries() -> [Entry] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appending(path: "record.json")),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.id == directory.lastPathComponent,
                  UUID(uuidString: entry.id) != nil else { return nil }
            // A record is written before moving; incomplete moves must not appear as disabled.
            guard SkillPinner.status(at: directory.appending(path: "skill")) != .absent else { return nil }
            return entry
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func archive(_ pin: DiscoveredSkillPin, name: String, allPins: [DiscoveredSkillPin]) throws -> Entry {
        guard pin.canArchive else { throw Failure.protected }
        let allowed = root.deletingLastPathComponent().appending(path: "\(pin.provider.directoryName)/skills")
        guard pin.url.isWithin(allowed), pin.url != allowed,
              pin.url.deletingLastPathComponent().resolvingSymlinksInPath().isWithin(allowed.agentBoundary(provider: pin.provider)) else {
            throw Failure.protected
        }
        guard SkillPinner.status(at: pin.url) != .absent else { throw Failure.missing }
        guard SkillPinner.dependents(of: pin, among: allPins).isEmpty else { throw Failure.dependents }
        let fm = FileManager.default
        let entry = Entry(id: UUID().uuidString, name: name, originalPath: pin.url.path, providerKey: pin.provider.key,
            createdAt: Date(), linkTarget: try? fm.destinationOfSymbolicLink(atPath: pin.url.path))
        let folder = root.appending(path: entry.id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entry).write(to: folder.appending(path: "record.json"), options: .atomic)
        do { try fm.moveItem(at: pin.url, to: folder.appending(path: "skill")) }
        catch {
            if SkillPinner.status(at: folder.appending(path: "skill")) == .absent { try? fm.removeItem(at: folder) }
            throw error
        }
        return entry
    }

    func restore(_ entry: Entry) throws {
        let fm = FileManager.default
        guard UUID(uuidString: entry.id) != nil, entry.originalPath.hasPrefix("/"),
              !URL(fileURLWithPath: entry.originalPath).isWithin(root) else { throw Failure.invalidBackup }
        let folder = root.appending(path: entry.id)
        guard let data = try? Data(contentsOf: folder.appending(path: "record.json")),
              let saved = try? JSONDecoder().decode(Entry.self, from: data),
              saved.id == entry.id, saved.originalPath == entry.originalPath else { throw Failure.invalidBackup }
        let source = folder.appending(path: "skill")
        let destination = URL(fileURLWithPath: entry.originalPath)
        let home = root.deletingLastPathComponent()
        let provider = AgentProvider.named(entry.providerKey)
        let allowed = home.appending(path: "\(provider.directoryName)/skills")
        guard destination.standardizedFileURL.path == entry.originalPath,
              destination.isWithin(allowed), destination != allowed,
              !destination.pathComponents.contains(".system"),
              destination.deletingLastPathComponent().resolvingSymlinksInPath().isWithin(allowed.agentBoundary(provider: provider)) else {
            throw Failure.invalidBackup
        }
        guard SkillPinner.status(at: source) != .absent else { throw Failure.missing }
        guard SkillPinner.status(at: destination) == .absent else { throw Failure.conflict }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // moveItem preserves the original (possibly relative) symlink text.
        try fm.moveItem(at: source, to: destination)
        try? fm.removeItem(at: folder)
    }
}
