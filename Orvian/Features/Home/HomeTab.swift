import SwiftUI

/// Onglet « Accueil » : navigation dans l'arborescence du drive.
struct HomeTab: View {
    let driveId: Int
    let router: ViewerRouter
    let isSelected: Bool
    @Binding var path: [DriveFile]

    /// Premier dossier du drive. Il devient la racine de navigation : la
    /// racine technique du drive n'est jamais ajoutée au NavigationStack et
    /// n'est donc pas accessible par retour.
    @State private var startDirectory: DriveFile?
    /// Vrai quand le dossier de démarrage vient d'être résolu par le réseau
    /// dans cette même session : la revalidation immédiate du NavigationStack
    /// relirait alors l'endpoint `.directory(1)` à quelques dixièmes de
    /// seconde d'intervalle. Un aller-retour par lancement est économisé.
    @State private var startDirectoryIsFresh = false
    private let service = KDriveService()

    private var cacheKey: String { "home_start_dir_locked_\(driveId)" }

    init(driveId: Int, router: ViewerRouter, isSelected: Bool, path: Binding<[DriveFile]>) {
        self.driveId = driveId
        self.router = router
        self.isSelected = isSelected
        self._path = path

        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(DriveFile.self, from: data) {
            _startDirectory = State(initialValue: cached)
        }
    }

    @ViewBuilder
    var body: some View {
        if let startDirectory {
            navigationRoot(startDirectory)
        } else {
            ProgressView("Ouverture de l’Accueil…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: driveId) {
                    await resolveStartDirectory()
                }
        }
    }

    private func navigationRoot(_ root: DriveFile) -> some View {
        NavigationStack(path: $path) {
            DirectoryView(
                directory: root,
                driveId: driveId,
                crumbs: [root.name],
                router: router,
                isActive: isSelected,
                showsSearchBar: true,
                onOpenFolder: { folder in
                    path.append(folder)
                }
            )
            .id(root.id)
            .navigationDestination(for: DriveFile.self) { directory in
                let index = path.firstIndex(where: { $0.id == directory.id })
                let crumbs = [root.name] + (index.map { Array(path[...$0].map(\.name)) } ?? [directory.name])
                DirectoryView(
                    directory: directory,
                    driveId: driveId,
                    crumbs: crumbs,
                    router: router,
                    isActive: isSelected,
                    showsSearchBar: true,
                    onOpenFolder: { folder in
                        path.append(folder)
                    }
                )
            }
        }
        .task(id: driveId) {
            await revalidateStartDirectory()
        }
    }

    /// Revalide en arrière-plan le dossier de démarrage : le dossier affiché
    /// au lancement provient d'un cache qui peut être obsolète (premier
    /// dossier renommé ou supprimé à distance). Sans cette relecture,
    /// l'Accueil restait bloqué sur un dossier disparu, sans moyen d'en
    /// sortir puisqu'il constitue la racine de la pile de navigation.
    private func revalidateStartDirectory() async {
        // Dossier tout juste résolu par le réseau : rien à revalider.
        if startDirectoryIsFresh {
            startDirectoryIsFresh = false
            return
        }
        guard let current = startDirectory else { return }

        let resolved: DriveFile
        if current.id == 1 {
            // La racine technique n'est qu'un repli de session après un échec
            // initial : retenter la résolution normale au lieu de la verrouiller.
            guard let page = try? await service.page(
                .directory(1), driveId: driveId, cursor: nil, forceNetwork: true
            ),
                  let directory = page.data?.first(where: \.isDirectory)
            else { return }
            resolved = directory
        } else {
            do {
                // La première page est limitée à 60 éléments. Interroger l'ID
                // verrouillé évite de le remplacer quand un autre dossier passe
                // simplement avant lui dans l'ordre alphabétique.
                let directory = try await service.fileInfo(driveId: driveId, fileId: current.id)
                guard directory.isDirectory else { return }
                resolved = directory
            } catch let APIError.http(status, _, _) where status == 404 || status == 410 {
                guard let page = try? await service.page(
                    .directory(1), driveId: driveId, cursor: nil, forceNetwork: true
                ),
                      let directory = page.data?.first(where: \.isDirectory)
                else { return }
                resolved = directory
            } catch {
                // Une panne réseau ou serveur ne prouve pas que le dossier a
                // disparu : conserver le verrou et la pile actuels.
                return
            }
        }
        guard !Task.isCancelled else { return }

        // Seule la disparition confirmée de l'ancienne racine autorise son
        // remplacement et la remise à zéro de la pile. Un renommage conserve
        // l'identité de navigation tout en rafraîchissant les métadonnées.
        if resolved.id != current.id {
            path.removeAll()
        }
        startDirectory = resolved

        if let data = try? JSONEncoder().encode(resolved) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// Résout le premier dossier du drive. L'ancien cache contient déjà ce
    /// dossier ; sans cache, une seule lecture de la racine technique suffit.
    private func resolveStartDirectory() async {
        let defaults = UserDefaults.standard
        var resolved: DriveFile?
        var fromNetwork = false

        if let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(DriveFile.self, from: data) {
            resolved = cached
        }

        if resolved == nil,
           let page = try? await service.page(.directory(1), driveId: driveId, cursor: nil) {
            resolved = page.data?.first(where: \.isDirectory)
            fromNetwork = true
        }

        guard !Task.isCancelled else { return }
        guard let resolved else {
            // Sans cache ni réseau, conserver un Accueil utilisable pour cette
            // session seulement. La résolution sera retentée au prochain départ.
            path.removeAll()
            startDirectory = DriveFile.root(name: "Accueil")
            startDirectoryIsFresh = false
            return
        }

        path.removeAll()
        startDirectory = resolved
        // La lecture réseau vient de vérifier le dossier : la revalidation
        // immédiate du NavigationStack n'a plus rien à apprendre.
        startDirectoryIsFresh = fromNetwork

        if let data = try? JSONEncoder().encode(resolved) {
            defaults.set(data, forKey: cacheKey)
        }

        // L'ancien cache n+1 pointait un niveau trop bas et ne doit plus être
        // repris par une future version.
        defaults.removeObject(forKey: "home_start_dir_n_plus_1_\(driveId)")
    }
}
