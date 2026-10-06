import Foundation
import CryptoKit
import Observation

/// Local scores are scoped to the credential, drive, content revision and model.
@MainActor
@Observable
final class ImageClassificationStore {
    static let shared = ImageClassificationStore()
    private(set) var revision = 0
    private(set) var persistenceError: String?
    var threshold: Float {
        didSet {
            if !threshold.isFinite { threshold = oldValue; return }
            threshold = min(0.99, max(0.50, threshold))
            guard threshold != oldValue else { return }
            defaults?.set(threshold, forKey: "imageClassificationThreshold")
            revision &+= 1
        }
    }

    @ObservationIgnored private var entries: [String: ImageClassificationRecord] = [:]
    @ObservationIgnored private var credentialFingerprint: String?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var writeSequence: UInt64 = 0
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<[String: ImageClassificationRecord], Never>?
    private let disk: ClassificationDiskStore
    private let currentCredential: () -> String?
    private let defaults: UserDefaults?

    init(directory: URL? = nil, defaults: UserDefaults? = .standard,
         credential: @escaping () -> String? = { TokenStore.credentialFingerprint() }) {
        self.defaults = defaults
        let saved = defaults?.object(forKey: "imageClassificationThreshold") as? NSNumber
        let value = saved?.floatValue ?? 0.80
        threshold = value.isFinite ? min(0.99, max(0.50, value)) : 0.80
        currentCredential = credential
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageClassification", isDirectory: true)
        disk = ClassificationDiskStore(directory: root)
    }

    func load(credentialFingerprint credential: String) async {
        guard currentCredential() == credential else { return }
        if credentialFingerprint != credential {
            resetSession()
            credentialFingerprint = credential
        }
        guard !loaded else { return }
        let capturedGeneration = generation
        if loadTask == nil {
            let disk = disk
            loadTask = Task { await disk.load(credential: credential) }
        }
        guard let task = loadTask else { return }
        let persisted = await task.value
        guard capturedGeneration == generation, currentCredential() == credential else { return }
        // Multiple callers may await the same load; never overwrite new results.
        guard !loaded else { return }
        entries.merge(persisted) { current, _ in current }
        loaded = true
        loadTask = nil
        revision &+= 1
    }

    func score(driveId: Int, file: DriveFile) -> Float? {
        guard loaded, credentialFingerprint == currentCredential(),
              let entry = entries[key(driveId: driveId, fileId: file.id)],
              entry.modelVersion == NSFWImageClassifier.modelVersion,
              entry.contentRevision == ImageContentRevision(file: file),
              entry.contentRevision != nil || entry.fileSize == file.size,
              entry.score.isFinite, (0...1).contains(entry.score) else { return nil }
        return entry.score
    }

    func snapshot(driveId: Int, items: [DriveFile]) -> ImageClassificationSnapshot {
        var scores: [Int: Float] = [:]
        for file in items where file.isImage {
            if let value = score(driveId: driveId, file: file) { scores[file.id] = value }
        }
        return ImageClassificationSnapshot(scores: scores)
    }

    func record(score: Float, file: DriveFile, driveId: Int,
                credentialFingerprint credential: String, modelVersion: String) async throws {
        guard score.isFinite, (0...1).contains(score) else { throw ClassificationError.invalidScores }
        guard loaded, credential == credentialFingerprint, credential == currentCredential() else {
            throw CancellationError()
        }
        entries[key(driveId: driveId, fileId: file.id)] = ImageClassificationRecord(
            score: score, contentRevision: ImageContentRevision(file: file),
            fileSize: file.size,
            modelVersion: modelVersion, analyzedAt: Date())
        if entries.count > 20_100 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.analyzedAt > $1.value.analyzedAt }
                .prefix(20_000).map { ($0.key, $0.value) })
        }
        revision &+= 1
        scheduleSave()
    }

    func flush() async throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard let credential = credentialFingerprint, loaded else { return }
        writeSequence &+= 1
        let sequence = writeSequence
        let records = persistentRecords()
        do {
            try await disk.save(records, credential: credential, sequence: sequence)
            if credentialFingerprint == credential { persistenceError = nil }
        } catch {
            if credentialFingerprint == credential { persistenceError = "Les résultats sont disponibles, mais leur sauvegarde locale a échoué." }
            throw error
        }
    }

    func resetSession() {
        pendingSave?.cancel()
        pendingSave = nil
        if loaded, let credential = credentialFingerprint {
            writeSequence &+= 1
            let sequence = writeSequence
            let records = persistentRecords()
            let disk = disk
            Task { try? await disk.save(records, credential: credential, sequence: sequence) }
        }
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        credentialFingerprint = nil
        loaded = false
        entries.removeAll()
        persistenceError = nil
        revision &+= 1
    }

    private func key(driveId: Int, fileId: Int) -> String { "\(driveId)|\(fileId)" }

    private func persistentRecords() -> [String: ImageClassificationRecord] {
        Dictionary(uniqueKeysWithValues: entries.filter { $0.value.contentRevision != nil }
            .sorted { $0.value.analyzedAt > $1.value.analyzedAt }.prefix(20_000).map { ($0.key, $0.value) })
    }

    private func scheduleSave() {
        // A scheduled write survives rapid results; this is a throttle, not a
        // debounce that could postpone persistence for the entire scan.
        guard pendingSave == nil else { return }
        let capturedGeneration = generation
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, capturedGeneration == self.generation else { return }
            self.pendingSave = nil
            try? await self.flush()
        }
    }
}

private actor ClassificationDiskStore {
    let directory: URL
    private var lastSequence: [String: UInt64] = [:]

    init(directory: URL) { self.directory = directory }

    private func fileURL(credential: String) -> URL {
        let namespace = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(namespace).appendingPathExtension("json")
    }

    func load(credential: String) -> [String: ImageClassificationRecord] {
        let url = fileURL(credential: credential)
        guard let data = try? Data(contentsOf: url), data.count <= 16 * 1024 * 1024,
              let records = try? JSONDecoder().decode([String: ImageClassificationRecord].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: records.filter { $0.value.contentRevision != nil }
            .sorted { $0.value.analyzedAt > $1.value.analyzedAt }.prefix(20_000).map { ($0.key, $0.value) })
    }

    func save(_ records: [String: ImageClassificationRecord], credential: String, sequence: UInt64) throws {
        guard sequence > (lastSequence[credential] ?? 0) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try JSONEncoder().encode(records).write(to: fileURL(credential: credential), options: .atomic)
        lastSequence[credential] = sequence
    }
}
