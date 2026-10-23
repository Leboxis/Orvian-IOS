import SwiftUI
import Translation

@MainActor @Observable
final class PreparedSubtitleJob {
    var status = "Prêt à analyser la vidéo entière."
    var progress = 0.0
    var isRunning = false
    var isReady = false
    var contextFallbackCount = 0
    var error: String?
    var configuration: TranslationSession.Configuration?
    var originalRun = UUID()
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var configuredSource: SubtitleSourceLanguage?
    @ObservationIgnored private var work: Task<Void, Never>?

    func start(source: SubtitleSourceLanguage) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        error = nil
        progress = 0
        contextFallbackCount = 0
        status = "Préparation des modèles…"
        if source == .french {
            configuration = nil
            configuredSource = nil
            originalRun = UUID()
            return
        }
        if configuration != nil, configuredSource == source {
            configuration?.invalidate()
            return
        }
        configuredSource = source
        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        if #available(iOS 26.4, *) {
            configuration = .init(source: sourceLanguage, target: .init(identifier: "fr"), preferredStrategy: .highFidelity)
        } else {
            configuration = .init(source: sourceLanguage, target: .init(identifier: "fr"))
        }
        configuration?.invalidate()
    }

    func cancel() {
        cancelled = true
        if let work { work.cancel() } else {
            isRunning = false
            status = "Préparation annulée."
        }
    }

    func run(key: PreparedSubtitleKey, session: TranslationSession?) async {
        guard isRunning, work == nil, !cancelled, !Task.isCancelled else { return }
        let task = Task { [self] in
            var temporaryDirectory: URL?
            defer {
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
            }
            do {
                // La transcription préparée est locale : l'autorisation du vieux
                // SFSpeechRecognizer (serveurs Apple) ne s'applique pas ici.
                try validate(key)
                if let session { try await session.prepareTranslation() }
                try validate(key)
                status = "Téléchargement de la vidéo…"
                let local = try await PreparedSubtitleDownload.fetch(key: key)
                temporaryDirectory = local.deletingLastPathComponent()
                try validate(key)
                status = "Transcription précise de l’audio…"
                var cues = try await PreparedParakeetAnalyzer.shared.transcribe(url: local, source: key.source) { [weak self] message, value in
                    await self?.setTranscriptionProgress(message, value: value * 0.65)
                }
                try validate(key)
                status = "Traduction des phrases en français…"
                for index in cues.indices {
                    try validate(key)
                    if let session {
                        if #available(iOS 26.4, *) {
                            let context = PreparedSubtitleContext(cues: cues, index: index)
                            let translated = try await context.translateCurrent(contextual: { text in
                                let response = try await session.translate(text)
                                return response.attributedTargetText
                            }, isolated: { text in
                                let response = try await session.translate(text)
                                return response.targetText
                            })
                            cues[index].french = translated.text
                            if context.hasContext, !translated.usedContext { contextFallbackCount += 1 }
                        } else {
                            let response = try await session.translate(cues[index].original)
                            cues[index].french = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } else {
                        guard key.source == .french else { throw PreparedSubtitleError.incomplete }
                        cues[index].french = cues[index].original
                    }
                    progress = 0.65 + 0.35 * Double(index + 1) / Double(cues.count)
                }
                try validate(key)
                try await PreparedSubtitleStore.shared.save(PreparedSubtitles(key: key, createdAt: Date(), cues: cues))
                try validate(key)
                isReady = true
                status = "Sous-titres prêts. Ils seront chargés automatiquement à l’ouverture de cette vidéo."
                if contextFallbackCount > 0 {
                    status += " \(contextFallbackCount) phrase(s) ont été traduites séparément car le moteur n’a pas conservé les repères du contexte. Les temps de l’audio sont conservés."
                }
            } catch is CancellationError {
                status = "Préparation annulée."
            } catch {
                self.error = (error as? PreparedSubtitleError)?.localizedDescription
                    ?? "La préparation a échoué. Vérifiez les modèles de langue, la connexion et l’espace disponible, puis réessayez."
            }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        work = nil
        isRunning = false
    }

    private func setTranscriptionProgress(_ message: String, value: Double) {
        status = message
        progress = value
    }
    private func validate(_ key: PreparedSubtitleKey) throws {
        try Task.checkCancellation()
        guard TokenStore.credentialFingerprint() == key.credential else { throw CancellationError() }
    }
}

/// Le fichier signé ne reçoit aucun en-tête d'authentification de l'API.
/// La source intégrale est temporaire et supprimée après analyse/annulation.
private enum PreparedSubtitleDownload {
    static func fetch(key: PreparedSubtitleKey) async throws -> URL {
        guard TokenStore.credentialFingerprint() == key.credential,
              let url = await MediaURLCache.shared.url(driveId: key.driveID, fileId: key.fileID),
              url.scheme?.lowercased() == "https" else { throw PreparedSubtitleError.download }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.url?.scheme?.lowercased() == "https",
              TokenStore.credentialFingerprint() == key.credential else { throw PreparedSubtitleError.download }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrvianSubtitleSources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        do {
            let local = directory.appendingPathComponent("source.mov")
            try FileManager.default.moveItem(at: temporary, to: local)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: local.path)
            return local
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct PreparedSubtitleSheet: View {
    let file: DriveFile
    let driveID: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SubtitleSettings.sourceKey) private var source = SubtitleSourceLanguage.english
    @State private var job = PreparedSubtitleJob()
    @State private var key: PreparedSubtitleKey?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(file.name).font(.headline)
                    Text("La vidéo entière est analysée sur cet appareil avant lecture. Les phrases complètes sont traduites puis conservées avec les temps de l’audio.")
                    if #available(iOS 26.4, *) {
                        Text("Contexte de traduction : les phrases des 8 secondes précédentes sont incluses. Une phrase à cheval sur cette limite est conservée entière.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Sur cette version d’iOS, la traduction reste phrase par phrase. Le contexte précédent nécessite iOS 26.4 ou plus.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Transcription : Parakeet Ultra, sur l’appareil. Le premier lancement télécharge environ 630 Mo de modèles, réutilisés pour les vidéos suivantes. Prévoyez de l’espace libre pour la vidéo et son audio temporaire.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if #available(iOS 26.4, *) {
                        Text("Si la traduction ne conserve pas les repères du contexte, la phrase concernée est traduite seule pour terminer la préparation sans répéter les phrases précédentes ni changer ses temps d’affichage.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("La qualité dépend de la voix et de l’enregistrement. Gardez cette fenêtre ouverte jusqu’à la fin.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Langue parlée", selection: $source) {
                        ForEach(SubtitleSourceLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.disabled(job.isRunning)
                }
                Section {
                    Text(job.status)
                    if job.isRunning { ProgressView(value: job.progress) }
                    if let error = job.error { Text(error).foregroundStyle(.red) }
                    Button(job.isReady ? "Recalculer les sous-titres français" : "Préparer les sous-titres français") {
                        guard let credential = TokenStore.credentialFingerprint() else { return }
                        key = PreparedSubtitleKey(credential: credential, driveID: driveID, file: file, source: source)
                        job.start(source: source)
                    }.disabled(job.isRunning)
                    if job.isReady, let key {
                        Button("Supprimer les sous-titres préparés", role: .destructive) {
                            Task {
                                await PreparedSubtitleStore.shared.remove(key)
                                job.isReady = false
                                job.status = "Sous-titres préparés supprimés."
                            }
                        }.disabled(job.isRunning)
                    }
                }
                Section("Modèle et licences") {
                    Text("Parakeet Ultra par Moondream, dérivé de NVIDIA Parakeet TDT 0.6B v3. Conversion Core ML INT8 par Fluid Inference. FluidAudio 0.17.7, licence Apache 2.0.")
                        .font(.footnote)
                    Link("Parakeet Ultra — modèle et attribution", destination: URL(string: "https://huggingface.co/moondream/parakeet-ultra")!)
                    Link("Licence du modèle : CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                }
            }
            .navigationTitle("Préparer les sous-titres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(job.isRunning ? "Annuler" : "Fermer") { job.cancel(); dismiss() }
            } }
        }
        .interactiveDismissDisabled(job.isRunning)
        .translationTask(job.configuration) { session in
            if let key { await job.run(key: key, session: session) }
        }
        .task(id: job.originalRun) {
            if let key, key.source == .french, job.isRunning { await job.run(key: key, session: nil) }
        }
        .task(id: source) {
            guard !job.isRunning, let credential = TokenStore.credentialFingerprint() else { return }
            let value = PreparedSubtitleKey(credential: credential, driveID: driveID, file: file, source: source)
            key = value
            let ready = await PreparedSubtitleStore.shared.load(value) != nil
            guard !Task.isCancelled, !job.isRunning, source == value.source else { return }
            job.isReady = ready
            job.error = nil
            job.status = ready ? "Des sous-titres préparés sont disponibles pour cette vidéo." : "Prêt à analyser la vidéo entière."
        }
        .onDisappear { job.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { job.cancel() } }
    }
}
