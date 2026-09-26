# Audit UX / fiabilité — 13 corrections implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corriger les points 2, 3, 5, 6, 7, 10, 11, 12, 13, 15, 16, 17 et 18 de l'audit, dans l'ordre qui minimise le risque de régression, puis vérifier et pousser sur `main`.

**Architecture:** Trois familles de corrections. (a) Des invariants d'isolation : le cache réseau, le cache d'instantanés de grille et la mémoïsation du filtre ne doivent pas se concurrencer. (b) Des corrections d'accessibilité et de confort visuel : un interrupteur global « réduire l'animation » et des comportements plus sobres. (c) Des corrections de cycle de vie d'interface : onglets conservés, pastille flottante, double-tap vidéo. L'ordre d'exécution suit les dépendances réelles : d'abord les invariants purs (aucune dépendance UI), ensuite la grille (10 avant 12 et 16), ensuite les cartes (7 avant 16), ensuite les visionneuses, enfin le chrome, et l'interrupteur d'accessibilité **en dernier** pour qu'il enveloppe aussi les animations introduites par les tâches précédentes.

**Tech Stack:** Swift 5 language mode, SwiftUI, iOS 26 deployment target, XcodeGen (`project.yml`), CI GitHub Actions (macOS 26) avec scripts de vérification Python + `swiftc`.

**Spec:** le message d'audit fourni par l'utilisateur (points 1–18 + debts). Le point 1 (faire tourner les tests XCTest en CI) est **hors périmètre** : la demande porte sur 2, 3, 5, 6, 7, 10, 11, 12, 13, 15, 16, 17, 18. Conséquence à garder en tête : **aucun changement ne peut être vérifié par compilation sur la machine de travail** (pas de Xcode sous Windows). La seule vérification exécutable localement est `python3 .github/scripts/check_performance_regressions.py` (assertions sur le source) ; les autres scripts exigent `swiftc`. D'où la décision de rendre chaque étape petite, sans changement de signature publique, et deules les sources déjà couvertes par des assertions CI.

## Global Constraints

- Ne jamais changer la signature d'un membre appelé depuis un autre fichier, sauf si *tous* les appelants sont mis à jour dans la même tâche.
- `Tests/FavoritesDiskCacheChecks.swift` (exécuté par `check_favorites_cache.py` sur le runner) assert des fragments de source : `FileGridView.swift` doit contenir `onToggleFavorite: { await viewModel.toggleFavorite(`, `FileGridViewModel.swift` doit contenir `FileGridMutationCenter.shared.isSnapshotStale(` et `let currentSnapshot = DirectoryListSnapshot(`, et dans `toggleFavorite` l'ordre `try await service.setFavorite(` < `.favorite(driveId:` < `} catch {` doit être préservé.
- `check_performance_regressions.py` assert notamment `shouldRetry: shouldRetryThumbnail` dans `FileCardView.swift`, `SharedRequests<String, ImageResult>()` dans `HiresImageStore.swift`, et l'ordre disque-avant-réseau dans `ThumbnailProvider.swift`.
- Commentaire et documentation en français, dans le style du fichier (justification du *pourquoi*, pas du *quoi*).
- Zéro commentaire de code ajouté au-delà de ceux justifiant un invariant non évident ; pas de refactor non demandé.
- Ne pas toucher aux points 1, 4, 8, 9, 14, ni aux sujets produit.

## Review Focus

Cinq entrées que l'audit n'énonce pas explicitement mais qu'un utilisateur reasonable de l'app-Pl encounterait, et que les tests de chaque tâche doivent pinner :

1. **Favori posé puis annulé par le serveur.** `toggleFavorite` fait deux mutations optimistes (/drapeau puis retrait dans l'onglet Favoris) ; si la copie d'instantané est coalescée, la tâche doit garantir qu'une seule révision est publiée et que le snapshot disk n'est jamais écrit avec un état intermédiaire.
2. **Rotation de l'appareil pendant l'ouverture d'une photo.** Le titre de la visionneuse doit se stabiliser en une passe avec la nouvelle largeur — donc la mesure doit venir du conteneur, jamais du titre (Task 9).
3. **Changement du cache réseau depuis les Réglages pendant qu'une liste paginée est ouverte.** La session doit être reconstruite sans invalider les requêtes en vol ni laisser l'ancien cache disque faire doubler la consommation (Task 2).
4. **Double-tap au-delà de la fenêtre de 300 ms.** Le tap différé ne doit jamais rester en attente et ne doit pas masquer les contrôles plus tard que prévu (Task 10).
5. **Return sur l'onglet Favoris après un import metering.** L'onglet conservé doit afficher l'état à jour sans squelette et sans perdre la position — donc le snapshot mémoire doit être lu après écriture, jamais avant (Tasks 6 et 12).

---

## File Structure

| Fichier | Rôle | Tâches |
|---|---|---|
| `Orvian/UI/Motion.swift` (nouveau) | Interrupteur global « réduire l'animation » + garde de publication | T0, T13 |
| `Orvian/App/RootView.swift` | Publie le réglage système à `Motion` | T0 |
| `Orvian/App/OrvianApp.swift` | Retire le doublon `URLCache.shared` | T2 |
| `Orvian/Core/API/APIClient.swift` | Un seul cache réseau, dimensionné par la préférence | T2 |
| `Orvian/Features/Settings/SettingsView.swift` | Réglage « Cache réseau » + garde d'animation | T2, T13 |
| `Orvian/Core/Cache/ThumbnailProvider.swift` | Dédoublonnage du préchargement en O(1) | T3 |
| `Orvian/Features/Shared/FileGridViewModel.swift` | Révision coalescée, cache du filtre, écritures d'instantané | T5, T6, T7 |
| `Orvian/Features/Shared/FileGridView.swift` | Lit les préférences une fois, plus de cache dans `@State` | T6, T8 |
| `Orvian/Features/Shared/FileCardView.swift` | Fond de miniature, préférences reçues | T8, T9 |
| `Orvian/UI/MediaChrome.swift` | Largeur de titre mesurée sur le conteneur | T11 |
| `Orvian/Features/Viewer/VideoPlayerView.swift` | Tap différé, double-tap sans clignotement | T10, T13 |
| `Orvian/App/MainTabView.swift` | Pastille flottante, onglets conservés | T12, T13 |
| `Orvian/UI/FloatingTabBar.swift` | Animation pilotée par la valeur, onglets conservés | T14 |
| 12 autres vues animées | Animations passées par `Motion` | T13 |
| `.github/scripts/check_motion_and_isolation.py` (nouveau) | Garde exécutable sur les invariants nouveaux | T15 |

---

### Task 1: Interrupteur global « réduire l'animation »

**Files:**
- Create: `Orvian/UI/Motion.swift`
- Modify: `Orvian/App/RootView.swift:10-46`

**Interfaces:**
- Produces: `enum Motion` avec `static func animation(_ animation: Animation) -> Animation?`, `static func publish(reduceMotion: Bool)`, `static var animationsEnabled: Bool`. `nil` = changement appliqué immédiatement.
- Produces: `extension View { func reduceMotionGate() -> some View }`.

- [ ] **Step 1: Créer `Orvian/UI/Motion.swift`**

```swift
import SwiftUI

/// Un seul interrupteur pour le réglage système « Réduire l'animation »
/// (Réglages → Accessibilité → Mouvement).
///
/// iOS désactive de lui-même certaines animations système, mais pas celles
/// écrites à la main : `withAnimation`, `.animation(_:value:)` et
/// `.transition` continuent de s'exécuter. Chaque site passe donc son animation
/// par `Motion.animation(_:)`, qui renvoie `nil` — « applique le changement
/// immédiatement » — quand l'utilisateur a demandé moins de mouvement. Un
/// `.transition` n'a pas besoin d'être traité : il ne s'anime que dans un
/// contexte d'animation, et ces contextes passent désormais tous par ici.
enum Motion {
    /// `false` tant que la racine n'a pas publié le réglage : le premier
    /// rendu animé est préférable à un état figé définitif.
    nonisolated(unsafe) private static var reduceMotion = false

    static var animationsEnabled: Bool { !reduceMotion }

    static func publish(reduceMotion: Bool) {
        Motion.reduceMotion = reduceMotion
    }

    /// `nil` rend l'application du changement instantanée, que ce soit dans
    /// `withAnimation` ou dans `.animation(_:value:)`.
    static func animation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

extension View {
    /// Publie le réglage système dans `Motion`. À poser une seule fois, à la
    /// racine : tous les sites d'animation de l'app le lisent ensuite.
    func reduceMotionGate() -> some View {
        modifier(ReduceMotionGate())
    }
}

private struct ReduceMotionGate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { Motion.publish(reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, enabled in
                Motion.publish(reduceMotion: enabled)
            }
    }
}
```

- [ ] **Step 2: Poser la garde à la racine**

Dans `RootView.body`, ajouter `.reduceMotionGate()` à la chaîne de modificateurs du `ZStack` racine (après `.onAppear { privacy.contentDidAppear() }`).

- [ ] **Step 3: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 4: Commit**

```bash
git add Orvian/UI/Motion.swift Orvian/App/RootView.swift
git commit -m "feat(motion): interrupteur global « réduire l'animation »"
```

---

### Task 2: Un seul cache réseau, dimensionné par l'utilisateur (point 15)

**Files:**
- Modify: `Orvian/App/OrvianApp.swift:7-17`
- Modify: `Orvian/Core/API/APIClient.swift:17,24-45`
- Modify: `Orvian/Features/Settings/SettingsView.swift` (espace « Cache »)

**Interfaces:**
- Consumes: `DiskImageCache` comme modèle du réglage existant (clé `thumbnailCacheLimitMB`).
- Produces: clé de préférence `networkCacheLimitMB` (Int, Mo, défaut 50).
- Produces: `APIClient.applyCacheSettings()` (actor, sans paramètre, sans valeur de retour).

- [ ] **Step 1: Retirer le doublon `URLCache.shared`**

Dans `OrvianApp.init`, supprimer le corps de la fonction et l'initialiseur (l'app n'a plus rien à configurer au lancement). Le fichier devient :

```swift
import SwiftUI

@main
struct OrvianApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
                .task {
                    await session.bootstrap()
                }
        }
    }
}
```

Le cache réseau n'est plus dimensionné qu'à un seul endroit (`APIClient`), ce qui supprime la contradiction entre les deux justifications de 150 Mo.

- [ ] **Step 2: Dimensionner le cache depuis la préférence**

Dans `APIClient`, remplacer `private let session: URLSession` par `private var session: URLSession`, et remplacer la closure `apiConfiguration` par une fonction :

```swift
    /// Un seul cache réseau pour toute l'app : celui de cette session. Le
    /// cache `URLCache.shared` n'est plus redimensionné au lancement, donc
    /// l'app ne conserve plus deux fois la même revalidation HTTP.
    private static func apiConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: currentCacheLimitBytes(),
            diskPath: "api-url-cache"
        )
        configuration.httpMaximumConnectionsPerHost = 8
        return configuration
    }

    /// Capacité du cache réseau lue dans les Réglages. `0` = illimité.
    static func currentCacheLimitMB() -> Int {
        let stored = UserDefaults.standard.object(forKey: "networkCacheLimitMB") as? Int
        return stored ?? 50
    }

    private static func currentCacheLimitBytes() -> Int {
        let megabytes = currentCacheLimitMB()
        return megabytes > 0 ? megabytes * 1024 * 1024 : Int.max
    }

    /// Applique une nouvelle limite sans redémarrer : la session est
    /// reconstruite autour d'un `URLCache` redimensionné. Le magasin disque
    /// porte le même `diskPath`, iOS éjecte donc au-delà de la nouvelle
    /// capacité ; les requêtes en vol se terminent sur l'ancienne session,
    /// dont les Annuler ne sont jamais appelés.
    func applyCacheSettings() {
        session = URLSession(configuration: Self.apiConfiguration())
    }
```

et l'initialiseur : `init(session: URLSession? = nil) { self.session = session ?? URLSession(configuration: APIClient.apiConfiguration()) }`.

- [ ] **Step 3: Réglage dans l'espace « Cache » des Réglages**

Dans `SettingsView`, ajouter `@AppStorage("networkCacheLimitMB") private var networkCacheLimitMB = 50` à côté de `@AppStorage("thumbnailCacheLimitMB")`, puis un `onChange` qui applique la nouvelle limite :

```swift
        .onChange(of: networkCacheLimitMB) { _, _ in
            Task { await APIClient.shared.applyCacheSettings() }
        }
```

et une ligne de réglage dans la même section que le sélecteur « Limite du cache » (ligne 320) :

```swift
                Picker("Cache réseau", selection: $networkCacheLimitMB) {
                    Text("Illimité").tag(0)
                    Text("25 Mo").tag(25)
                    Text("50 Mo").tag(50)
                    Text("100 Mo").tag(100)
                    Text("250 Mo").tag(250)
                }
```

- [ ] **Step 4: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

Run: `Select-String -Path Orvian/**/*.swift -Pattern "URLCache.shared"` (via `grep`)
Expected: aucune occurrence.

- [ ] **Step 5: Commit**

```bash
git add Orvian/App/OrvianApp.swift Orvian/Core/API/APIClient.swift Orvian/Features/Settings/SettingsView.swift
git commit -m "fix(cache): un seul cache réseau, piloté par les Réglages"
```

---

### Task 3: Dédoublonnage du préchargement en O(1) (point 11)

**Files:**
- Modify: `Orvian/Core/Cache/ThumbnailProvider.swift:285-312`

**Interfaces:**
- Consumes: rien.
- Produces: rien (comportement identique, complexité constante).

- [ ] **Step 1: Remplacer la recherche linéaire**

Dans `prefetch(driveId:fileIds:isTrashed:)`, remplacer l'accumulation `newestKeys` par un ensemble de suivi :

```swift
        var seen = Set<Key>()
        var newestKeys: [Key] = []
        for fileId in fileIds {
            let key = Key(
                credentialFingerprint: credentialFingerprint,
                driveId: driveId,
                fileId: fileId,
                isTrashed: isTrashed
            )
            guard inFlight[key] == nil,
                  Self.memory.object(forKey: key.nsString) == nil,
                  !hasDiskEntry(key)
            else { continue }
            // `Set` plutôt que `contains` sur le tableau : 100 fichiers à
            // préparer coûtaient ~5 000 comparaisons de clés.
            guard seen.insert(key).inserted else { continue }
            newestKeys.append(key)
        }
```

- [ ] **Step 2: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed` (le script assert `if let image = await loadFromDisk(key)` et l'ordre avant `return await fetch(key:)`, tous deux intacts).

- [ ] **Step 3: Commit**

```bash
git add Orvian/Core/Cache/ThumbnailProvider.swift
git commit -m "perf(thumbnails): dédoublonnage du préchargement en temps constant"
```

---

### Task 4: Une seule révision de liste par opération logique (point 13)

**Files:**
- Modify: `Orvian/Features/Shared/FileGridViewModel.swift:9-33,74-90`

**Interfaces:**
- Produces: `withoutSnapshot(_:)` coalesce désormais **aussi** `itemsRevision` (le compte promis dans son commentaire depuis le début).

- [ ] **Step 1: Différer la révision pendant une opération groupée**

Remplacer le `didSet` de `items` :

```swift
    private(set) var items: [DriveFile] = [] {
        didSet {
            // Version incrémentale du contenu : les clés de mémoïsation des
            // vues (cache des filtres, tâches de pagination et de métadonnées)
            // s'appuient sur ce compteur au lieu de relire tout le tableau à
            // chaque rendu — un coût O(n) par frame sur les très grandes
            // listes. Toute mutation passe ici, y compris la modification
            // d'un élément (nom, favori, couleur, tags), le tri ou l'ajout
            // paginé, car un tableau valeur est réécrit en entier.
            // Dans une opération groupée (`withoutSnapshot`), la révision
            // n'estbuminée qu'une fois à la fin : `mergeUploaded` faisait
            // removeAll + append + sort, soit trois redessins de la grille
            // pour un seul import confirmé.
            if snapshotSuppressionDepth > 0 {
                revisionBumpPending = true
            } else {
                itemsRevision &+= 1
            }
            // Les mutations locales (corbeille, déplacement, import, favoris,
            // renommage…) resynchronisent l'entrée de cache : une réouverture
            // de la liste affiche immédiatement l'état à jour.
            // Regroupées via `withoutSnapshot`, plusieurs mutations
            // synchrones (ex. removeAll + append + sort) ne stockent qu'une
            // fois au lieu de N fois.
            if loadedOnce {
                if snapshotSuppressionDepth > 0 {
                    snapshotDirtyWhileSuppressed = true
                } else {
                    storeListSnapshot()
                }
            }
        }
    }
```

- [ ] **Step 2: Bumper la révision à la fin du groupe**

Ajouter `private var revisionBumpPending = false` à côté de `snapshotDirtyWhileSuppressed`, et réécrire le `defer` de `withoutSnapshot` :

```swift
    private func withoutSnapshot<T>(_ work: () -> T) -> T {
        snapshotSuppressionDepth += 1
        defer {
            snapshotSuppressionDepth = max(0, snapshotSuppressionDepth - 1)
            guard snapshotSuppressionDepth == 0 else { return }
            if revisionBumpPending {
                revisionBumpPending = false
                itemsRevision &+= 1
            }
            if snapshotDirtyWhileSuppressed, loadedOnce {
                snapshotDirtyWhileSuppressed = false
                storeListSnapshot()
            }
        }
        return work()
    }
```

L'ordre est délibéré : la révision passe d'abord, pour que la grille re-rende avec le compteur à jour, puis l'instantané est écrit.

- [ ] **Step 3: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 4: Commit**

```bash
git add Orvian/Features/Shared/FileGridViewModel.swift
git commit -m "perf(grid): une seule révision de liste par opération groupée"
```

---

### Task 5: Sortir le cache du filtre de `@State` (point 10)

**Files:**
- Modify: `Orvian/Features/Shared/FileGridView.swift:82-85,409-427,824-870`
- Modify: `Orvian/Features/Shared/FileGridViewModel.swift` (nouveau stockage `@ObservationIgnored`)

**Interfaces:**
- Produces: `VisibleItemsKey` et `VisibleItemsCache` passent de `fileprivate` à interne, pour être stockés par le vue-modèle.
- Produces: `FileGridViewModel.visibleItems(key:mediaMetadata:) -> [DriveFile]`.

- [ ] **Step 1: Rendre les deux types visibles depuis le vue-modèle**

Dans `FileGridView.swift`, changer `fileprivate struct VisibleItemsKey` en `struct VisibleItemsKey` et `@MainActor private struct VisibleItemsCache` en `@MainActor struct VisibleItemsCache`, puis supprimer la méthode `mutating` au profit d'une méthode qui mute une référence… non : conserver `mutating`, le stockage n'est plus dans `@State`.

- [ ] **Step 2: Stocker le cache dans le vue-modèle**

Dans `FileGridViewModel`, ajouter :

```swift
    /// Mémoïsation du filtre/tri de la grille. Elle vit ici, et non dans un
    /// `@State` de la vue : la muter pendant l'évaluation du `body` est
    /// précisément ce que SwiftUI signale comme écriture d'état pendant une
    /// mise à jour (comportement non défini, avertissements en console,
    /// redessins en boucle). Le composant qui possède les données possède
    /// donc aussi le calcul dérivé, et rien n'est écrit pendant le rendu.
    @ObservationIgnored private var visibleItemsCache = VisibleItemsCache()

    func visibleItems(key: VisibleItemsKey, mediaMetadata: MediaMetadataStore) -> [DriveFile] {
        visibleItemsCache.visibleItems(
            key: key,
            items: items,
            mediaMetadata: mediaMetadata
        )
    }
```

- [ ] **Step 3: Adapter la grille**

Dans `FileGridView`, supprimer `@State private var visibleItemsCache = VisibleItemsCache()` et réécrire l'accesseur :

```swift
    private var visibleItems: [DriveFile] {
        viewModel.visibleItems(key: visibleItemsKey, mediaMetadata: mediaMetadata)
    }
```

- [ ] **Step 4: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

Run: `grep "visibleItemsCache" Orvian` → seule la déclaration du vue-modèle et l'appel interne subsistent.

- [ ] **Step 5: Commit**

```bash
git add Orvian/Features/Shared/FileGridView.swift Orvian/Features/Shared/FileGridViewModel.swift
git commit -m "fix(grid): plus d'écriture d'état pendant le rendu de la grille"
```

---

### Task 6: Écriture d'instantané hors du chemin chaud (point 12)

**Files:**
- Modify: `Orvian/Features/Shared/FileGridViewModel.swift:359-375,484-517,118-206`

**Interfaces:**
- Produces: `commitListSnapshot()` — écrit l'instantané immédiatement (utilisé par le flush).
- Consumes: `FileGridMutationCenter.shared.isSnapshotStale` (inchangé).

- [ ] **Step 1: Écrire l'instantané dans la vue-modèle, pas dans le store**

Remplacer `storeListSnapshot()` par :

```swift
    /// Écrit (ou réécrit) l'instantané de la liste dans le cache mémoire.
    ///
    /// L'écriture est **différée et regroupée** : le store mémoire conserve
    /// le tableau `items` vivant, si bien que la mutation suivante devait
    /// recopier la liste entière (5 000 fiches sur un gros dossier) pour
    /// contentious la copie sur writing. Chaque étoile posée paie donc ce
    /// coût. En n'écrivant qu'une fois par salve, le tampon reste unique
    /// entre deux écritures et les mutations redeviennent en place.
    private func storeListSnapshot() {
        guard credentialFingerprint == TokenStore.credentialFingerprint() else { return }
        guard !snapshotWriteScheduled else { return }
        snapshotWriteScheduled = true
        Task { @MainActor [weak self] in
            // Laisse les mutations synchrones du même tour se réunir.
            await Task.yield()
            guard let self, self.loadedOnce else { return }
            self.snapshotWriteScheduled = false
            self.commitListSnapshot()
        }
    }

    private func commitListSnapshot() {
        guard credentialFingerprint == TokenStore.credentialFingerprint() else { return }
        DirectoryListStore.shared.store(
            source: source,
            driveId: driveId,
            orderBy: orderBy,
            order: order,
            items: items,
            cursor: cursor,
            hasMore: hasMore,
            totalItemCount: totalItemCount,
            fetchedAt: fetchedAt
        )
    }
```

Ajouter `private var snapshotWriteScheduled = false`.

- [ ] **Step 2: Écrire avant de lire, jamais l'inverse**

Dans `loadIfNeeded`, au tout début de la branche `if loadedOnce {`, insérer `flushPendingSnapshot()` avant de construire `currentSnapshot`, et dans la branche où le snapshot mémoire est lu (`let memorySnapshot = ...`), faire le flush **avant** l'appel à `DirectoryListStore.shared.snapshot(...)` — c'est-à-dire juste avant `let restoreGeneration = dataGeneration`, en appelant `flushPendingSnapshot()`.

Ajouter :

```swift
    /// Écrit immédiatement l'instantané en attente : un état plus récent ne
    /// doit jamais être masqué par une entrée plus ancienne au remontage.
    private func flushPendingSnapshot() {
        guard snapshotWriteScheduled else { return }
        snapshotWriteScheduled = false
        commitListSnapshot()
    }
```

- [ ] **Step 3: Grouper les mutations optimistes du favori**

Dans `toggleFavorite`, entourer les mutations optimistes d'un seul `withoutSnapshot` :

```swift
        mutationErrorMessage = nil
        let oldValue = items[index].isFavorite
        let newValue = !(oldValue ?? false)
        let shouldRemove = source == .favorites && !newValue
        // Une seule révision et un seul instantané pour les deux mutations
        // (drapeau, puis retrait de l'onglet Favoris).
        withoutSnapshot {
            items[index].isFavorite = newValue
        }
        do {
            try await service.setFavorite(driveId: driveId, fileId: file.id, favorite: newValue)
            if shouldRemove {
                withoutSnapshot {
                    items.removeAll { $0.id == file.id }
                }
            }
            FileGridMutationCenter.shared.publish(
                .favorite(driveId: driveId, fileId: file.id, isFavorite: newValue)
            )
            return true
        } catch {
```

L'ordre exigé par `FavoritesDiskCacheChecks` (`try await service.setFavorite(` < `.favorite(driveId:` < `} catch {`) est préservé.

- [ ] **Step 4: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 5: Commit**

```bash
git add Orvian/Features/Shared/FileGridViewModel.swift
git commit -m "perf(grid): instinct d'instantané groupé, hors du chemin du favori"
```

---

### Task 7: Fond de miniature à l'apparition (point 7)

**Files:**
- Modify: `Orvian/Features/Shared/FileCardView.swift:184-210`

**Interfaces:**
- Consumes: `Motion.animation(_:)`, `\.accessibilityReduceMotion`.

- [ ] **Step 1: Fondu de 0,2 s à l'arrivée de l'image**

Dans `FileCardView`, ajouter `@Environment(\.accessibilityReduceMotion) private var reduceMotion` et remplacer le construct `if let thumbnail` :

```swift
    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                // L'image remplace l'icône typée sans coupure : sur un scroll
                // rapide, la substitution instantanée scintillait.
                .transition(.opacity)
                .animation(Motion.animation(.easeOut(duration: 0.2)), value: thumbnail)
        } else if thumbnailLoaded {
```

- [ ] **Step 2: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed` — en particulier `shouldRetry: shouldRetryThumbnail` est toujours présent.

- [ ] **Step 3: Commit**

```bash
git add Orvian/Features/Shared/FileCardView.swift
git commit -m "feat(grid): fondu de miniature à l'apparition"
```

---

### Task 8: Préférences lues une fois par grille (point 16)

**Files:**
- Modify: `Orvian/Features/Shared/FileGridView.swift:50-57,636-665`
- Modify: `Orvian/Features/Shared/FileCardView.swift:44-48,151-157,212-215`

**Interfaces:**
- Produces: `FileCardView` paramètres `showFileSizes: Bool = true` et `defaultFolderColor: String = "#4285F5"`.
- Consumes: `showsFavoriteBadge` déjà transmis (l'étoile n'est plus relue par la carte).

- [ ] **Step 1: Lire les trois préférences au niveau de la grille**

Dans `FileGridView`, ajouter `@AppStorage("showFileSizes") private var showFileSizes = true` et `@AppStorage("defaultFolderColor") private var defaultFolderColor = "#4285F5"` à côté des préférences existantes, puis transmettre les trois valeurs dans `cell(_:index:siblings:)` :

```swift
            showsFavoriteBadge: showFavoriteStars,
            showFileSizes: showFileSizes,
            defaultFolderColor: defaultFolderColor,
```

- [ ] **Step 2: Supprimer les abonnements de la carte**

Dans `FileCardView`, remplacer les trois `@AppStorage` par :

```swift
    /// Préférence globale : conserve le type comme repère lorsque le poids est masqué.
    /// Lue par la grille et transmise, pas observée par chaque carte.
    var showFileSizes = true
    /// Couleur de repli des dossiers sans couleur API, lue par la grille.
    var defaultFolderColor = "#4285F5"
```

et remplacer la condition `} else if showsFavoriteBadge && showFavoriteStars {` par `} else if showsFavoriteBadge {` (la grille applique déjà `showFavoriteStars`).

Résultat : une carte n'a plus aucun `@AppStorage` ; une grille de 150 vignettes n'a plus 450 abonnements.

- [ ] **Step 3: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 4: Commit**

```bash
git add Orvian/Features/Shared/FileGridView.swift Orvian/Features/Shared/FileCardView.swift
git commit -m "perf(grid): préférences lues une fois, plus 450 abonnements par grille"
```

---

### Task 9: Largeur du titre mesurée sur le conteneur (point 17)

**Files:**
- Modify: `Orvian/UI/MediaChrome.swift:8-51`

**Interfaces:**
- Consumes: `Motion.animation(_:)`.
- Produces: `MediaTitlePill(name:sideInsetFraction:)` — signature inchangée.

- [ ] **Step 1: Mesurer l'espace offert, pas la pastille**

Remplacer le corps de `MediaTitlePill` :

```swift
    @State private var containerWidth: CGFloat = 0
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        // La largeur utile est celle **offerte** par l'écran, relevée sur un
        // gabarit transparent qui la remplit. Mesurer la pastille elle-même
        // créait une boucle : son padding dépendait de sa propre largeur,
        // donc le titre se recalculait à chaque passe — un saut à
        // l'apparition, deux images pour se stabiliser en rotation.
        Color.clear
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .overlay {
                Group {
                    if copied {
                        Label("Copié", systemImage: "doc.on.doc")
                            .font(.footnote.weight(.medium))
                    } else {
                        Text(name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black.opacity(0.25), in: Capsule())
                .contentShape(Capsule())
                .padding(.horizontal, containerWidth * sideInsetFraction)
                .onTapGesture {
                    UIPasteboard.general.string = name
                    copied = true
                    scheduleReset()
                }
            }
            .onChange(of: name) { _, _ in
                // Changement de média : l'accusé « Copié » ne doit pas suivre.
                resetTask?.cancel()
                copied = false
            }
            .onDisappear {
                resetTask?.cancel()
            }
    }
```

Le `.padding(.horizontal, 14)` de l'ancien code (qui encadrait la mesure) disparaît avec lui ; l'ancien `.frame(maxWidth: .infinity)` est devenu le gabarit `Color.clear`.

- [ ] **Step 2: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 3: Commit**

```bash
git add Orvian/UI/MediaChrome.swift
git commit -m "fix(media): largeur du titre mesurée sur le conteneur"
```

---

### Task 10: Double-tap vidéo sans clignotement (point 5)

**Files:**
- Modify: `Orvian/Features/Viewer/VideoPlayerView.swift:126-141,318-353,1148-1183`

**Interfaces:**
- Produces: `pendingToggleTask: Task<Void, Never>?` — annulé à chaque sortie de page.

- [ ] **Step 1: Différer la bascule des contrôles**

Ajouter l'état à côté de `hideControlsTask` :

```swift
    // Masquage automatique des contrôles après 2.5 secondes
    @State private var showControls = true
    @State private var hideControlsTask: Task<Void, Never>?
    /// Bascule descontrols en attente : le premier tap d'un double-tap ne
    /// doit pas les masquer, sinon le second les fait revenir (clignotement
    /// de 0 à 300 ms à chaque saut de 10 s).
    @State private var pendingToggleTask: Task<Void, Never>?
```

- [ ] **Step 2: Réécrire `handleVideoTap`**

```swift
    /// Simple tap : la bascule des contrôles est différée de 250 ms — la
    /// fenêtre de désambiguïsation du double-tap. Un second tap annule
    /// l'attente et ne fait que sauter de 10 s : les contrôles ne bougent
    /// donc jamais, ni à l'aller ni au retour.
    private func handleVideoTap(at location: CGPoint) {
        let now = Date()
        let isDoubleTap = lastTapDate.map {
            now.timeIntervalSince($0) < 0.3
                && abs(location.x - lastTapLocation.x) < 44
                && abs(location.y - lastTapLocation.y) < 44
        } ?? false

        if isDoubleTap {
            pendingToggleTask?.cancel()
            pendingToggleTask = nil
            lastTapDate = nil
            guard player != nil, !hasFailedSetup, !isScrubbing, !isSeeking else { return }
            let onLeftHalf = location.x * 2 < videoAreaWidth
            // En RTL, l'avance se fait côté gauche (lecture inversée).
            let forward = layoutDirection == .rightToLeft ? onLeftHalf : !onLeftHalf
            skipTime(by: forward ? 10 : -10)
        } else {
            lastTapDate = now
            lastTapLocation = location
            pendingToggleTask?.cancel()
            pendingToggleTask = Task {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.pendingToggleTask = nil
                self.toggleControls()
            }
        }
    }
```

et supprimer `cancelPendingToggle()` (plus aucun appelant).

- [ ] **Step 3: Annuler l'attente quand la page sort**

Dans `hiddenControlGestureRegion(height:)`, le tap doit annuler l'attente avant de basculer :

```swift
            .onTapGesture {
                guard !showControls else { return }
                pendingToggleTask?.cancel()
                pendingToggleTask = nil
                toggleControls()
            }
```

Dans `.onChange(of: isActive)` (branche `else`, page quittée) et dans `.onDisappear`, ajouter `pendingToggleTask?.cancel()` et `pendingToggleTask = nil`.

- [ ] **Step 4: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 5: Commit**

```bash
git add Orvian/Features/Viewer/VideoPlayerView.swift
git commit -m "fix(video): double-tap sans clignotement des contrôles"
```

---

### Task 11: La pastille flotte, la grille ne bouge plus (point 6)

**Files:**
- Modify: `Orvian/App/MainTabView.swift:20-23,38-77,156-201`

**Interfaces:**
- Consumes: `DS.floatingBarInset` (110 pt) qui réserve déjà la place de la barre **et** de la pastille.
- Produces: `TransferOverlayChrome(uploadManager:onShowUploads:)` — le paramètre `onHeightChange` disparaît (structure privée, un seul appelant).

- [ ] **Step 1: Retirer la réservation d'espace**

Dans `MainTabView.body`, supprimer le `.safeAreaInset(edge: .bottom, spacing: 0) { … }` appliqué à `tabs` et l'état `@State private var overlayChromeHeight`. Le `ZStack(alignment: .bottom)` devient :

```swift
        ZStack(alignment: .bottom) {
            tabs

            // Barre et pastilles partagent le même bloc ancré en bas : la
            // pastille apparaît **au-dessus** de la grille, qui ne se décale
            // plus. Avant, une réserve d'espace était ajoutée sous le contenu
            // et animée — un import poussait la liste de 110 points sous le
            // doigt. `DS.floatingBarInset` réserve déjà la hauteur des deux.
            VStack(spacing: 0) {
                TransferOverlayChrome(
                    uploadManager: uploadManager,
                    onShowUploads: { showUploadSheet = true }
                )

                FloatingTabBar(
                    selection: $shell.tab,
                    onSelect: { targetTab in
                        guard targetTab == .profile else { return }
                        // Démarre au clic, avant que ProfileView soit montée.
                        // Sa propre tâche rejoint ensuite la même requête.
                        Task {
                            await RecentUploadsLoader.shared.prefetch(driveId: drive.id)
                        }
                    },
                    onReselect: { targetTab in
                        shell.navState.reset(
                            tab: targetTab,
                            scrollFavoritesToTop: favoritesReselectScrollToTop
                        )
                    }
                )
            }
            .padding(.bottom, 4)
        }
```

- [ ] **Step 2: Alléger `TransferOverlayChrome`**

Dans `TransferOverlayChrome`, supprimer le paramètre `onHeightChange` et le modificateur `.onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in onHeightChange(height) }`.

- [ ] **Step 3: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 4: Commit**

```bash
git add Orvian/App/MainTabView.swift
git commit -m "fix(chrome): la pastille d'upload flotte sans décaler la grille"
```

---

### Task 12: Onglets conservés entre deux visites (point 3)

**Files:**
- Modify: `Orvian/App/MainTabView.swift:3-12,135-150`
- Modify: `Orvian/UI/FloatingTabBar.swift:84-123`

**Interfaces:**
- Produces: `AppTab.isKeptAlive: Bool` — `true` pour `.home`, `.favorites`, `.tag`.

- [ ] **Step 1: Déclarer les onglets conservés**

Dans `FloatingTabBar.swift`, ajouter à `enum AppTab` :

```swift
    /// Onglets conservés montés entre deux visites : leurs données et leur
    /// position de défilement survivent, ce qui supprime le squelette et le
    /// retour en haut à chaque aller-retour. Profil et Réglages sont recréés
    /// à chaque visite — leur contenu est peu coûteux à reconstruire et le
    /// gain de mémoire vaut le coup.
    var isKeptAlive: Bool {
        switch self {
        case .home, .favorites, .tag: return true
        case .settings, .profile: return false
        }
    }
```

- [ ] **Step 2: Monter les onglets conservés en permanence**

Dans `MainTabView.tabPane(_:content:)` :

```swift
    @ViewBuilder
    private func tabPane(_ target: AppTab, @ViewBuilder content: () -> some View) -> some View {
        // Accueil, Favoris et Tag restent montés (données et position de
        // défilement conservées) ; les ongletsTINGS et Profil ne sont montés
        // que lorsqu'ils sont sélectionnés, ce qui libère leurs vues à chaque
        // changement d'onglet.
        if target.isKeptAlive || target == shell.tab {
            content()
                .opacity(shell.tab == target ? 1 : 0)
                .allowsHitTesting(shell.tab == target)
                .accessibilityHidden(shell.tab != target)
        } else {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
```

et mettre à jour le commentaire de tête de `MainTabView` (lignes 3-12) pour décrire la nouvelle règle.

- [ ] **Step 3: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 4: Commit**

```bash
git add Orvian/App/MainTabView.swift Orvian/UI/FloatingTabBar.swift
git commit -m "perf(tabs): Accueil, Favoris et Tag conservés entre deux visites"
```

---

### Task 13: Animation d'onglet pilotée par la valeur (point 18)

**Files:**
- Modify: `Orvian/UI/FloatingTabBar.swift:11-37`

**Interfaces:**
- Consumes: `Motion.animation(_:)`.

- [ ] **Step 1: Déplacer l'animation hors du gestionnaire de tap**

Dans `FloatingTabBar.body`, retirer le `withAnimation` de l'action et l'appliquer sur la barre :

```swift
    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    if selection == tab {
                        onReselect?(tab)
                    } else {
                        onSelect?(tab)
                        selection = tab
                    }
                }
            }
        }
        // L'animation est attachée à la **valeur** et non au tap : un
        // changement d'onglet obtenu autrement (remise à zéro au second
        // appui, ouverture automatique) anime exactement comme un tap.
        .animation(Motion.animation(.snappy(duration: 0.25)), value: selection)
        .padding(.horizontal, 10)
```

- [ ] **Step 2: Vérifier**

Run: `python3 .github/scripts/check_performance_regressions.py`
Expected: `Performance regression checks passed`

- [ ] **Step 3: Commit**

```bash
git add Orvian/UI/FloatingTabBar.swift
git commit -m "fix(tabs): animation d'onglet attachée à la valeur"
```

---

### Task 14: Passer toutes les animations restantes par l'interrupteur (point 2)

**Files:**
- Modify: `Core/Upload/UploadManager.swift:666`
- Modify: `Features/Favorites/FavoritesView.swift:194`
- Modify: `Features/Home/DirectoryView.swift:187`
- Modify: `Features/Security/AppLockSetupSheet.swift:57,191,194`
- Modify: `Features/Security/AppLockView.swift:116,185,189,215,221,254,257`
- Modify: `Features/Security/CodeEntryControls.swift:23,89`
- Modify: `Features/Settings/SettingsView.swift:515,693`
- Modify: `Features/Shared/FileGridView.swift:378`
- Modify: `Features/Tag/TagsView.swift:53,318,680`
- Modify: `Features/Viewer/MediaPagerView.swift:315,708,765,771,793,848,861`
- Modify: `Features/Viewer/ScrubberBar.swift:55`
- Modify: `Features/Viewer/TextFileViewer.swift:74,249`
- Modify: `Features/Viewer/VideoPlayerView.swift:199,336,345,1200,1207`
- Modify: `UI/MediaChrome.swift:58`
- Modify: `UI/UploadProgressSheet.swift:57`
- Modify: `UI/FloatingTabBar.swift:59` (rebond d'icône)

**Interfaces:**
- Consumes: `Motion.animation(_:)`, `Motion.animationsEnabled`.

- [ ] **Step 1: Envelopper les animations par valeur**

Pour chaque site `.animation(X, value: V)`, remplacer par `.animation(Motion.animation(X), value: V)`. Sites : `MainTabView:48,194,195` (fait en Task 11 pour la zone supprimée ; vérifier), `FavoritesView:194`, `DirectoryView:187`, `AppLockSetupSheet:57`, `AppLockView:116`, `CodeEntryControls:23,89`, `SettingsView:515,693`, `ScrubberBar:55`, `VideoPlayerView:199,1290,1310`.

- [ ] **Step 2: Envelopper les `withAnimation`**

Pour chaque site `withAnimation(X) {`, remplacer par `withAnimation(Motion.animation(X)) {`. Sites : `UploadManager:666`, `AppLockSetupSheet:191,194`, `AppLockView:185,189,215,221,254,257`, `FileGridView:378`, `TagsView:53,318,680`, `MediaPagerView:315,708,765,771,793,848,861`, `TextFileViewer:74,249`, `VideoPlayerView:336,345,1200,1207`, `MediaChrome:58`, `UploadProgressSheet:57`.

`UploadProgressSheet:57` est un `withAnimation {` sans argument : le remplacer par `withAnimation(Motion.animation(.default)) {`.

- [ ] **Step 3: Désactiver le rebond d'icône sous réduction du mouvement**

Dans `FloatingTabBar.TabButton`, remplacer `.symbolEffect(.bounce, value: isSelected)` par :

```swift
                Image(systemName: isSelected ? tab.symbolFilled : tab.symbol)
                    .font(.system(size: 19, weight: .medium))
                    .modifier(SymbolBounce(enabled: isSelected && Motion.animationsEnabled))
```

et ajouter dans le même fichier :

```swift
/// Rebond de l'icône à la sélection, désactivé quand l'utilisateur a demandé
/// moins de mouvement.
private struct SymbolBounce: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.symbolEffect(.bounce, value: enabled)
        } else {
            content
        }
    }
}
```

- [ ] **Step 4: Vérifier qu'aucun site n'est resté**

Run: `python3 -c "import pathlib,re,sys;bad=[(p,i,l) for p in pathlib.Path('Orvian').rglob('*.swift') for i,l in enumerate(p.read_text(encoding='utf-8').splitlines(),1) if re.search(r'withAnimation\((?!Motion)',l) or re.search(r'\.animation\((?!Motion)',l)];[print(f'{p}:{i}: {l.strip()}') for p,i,l in bad];sys.exit(1 if bad else 0)"`
Expected: aucune sortie, code 0.

- [ ] **Step 5: Commit**

```bash
git add Orvian
git commit -m "feat(a11y): toutes les animations respectent « réduire l'animation »"
```

---

### Task 15: Garde exécutable et vérification finale

**Files:**
- Create: `.github/scripts/check_motion_and_isolation.py`
- Modify: `.github/workflows/build.yml` (une étape)

**Interfaces:**
- Consumes: les sources du projet.

- [ ] **Step 1: Écrire le script de garde**

```python
"""Keep the audited invariants: single motion switch, single network cache,
no state written while the grid renders, bounded tab lifetime."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def every_swift():
    return sorted(ROOT.glob("Orvian/**/*.swift"))


motion = source("Orvian/UI/Motion.swift")
assert "static func animation(_ animation: Animation) -> Animation?" in motion
assert "reduceMotion ? nil : animation" in motion
assert "reduceMotionGate()" in source("Orvian/App/RootView.swift")

# Aucun site d'animation ne doit contourner l'interrupteur.
offenders = []
pattern = re.compile(r"withAnimation\((?!Motion)|\.animation\((?!Motion)")
for path in every_swift():
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if pattern.search(line):
            offenders.append(f"{path.relative_to(ROOT)}:{number}")
assert not offenders, "Animations hors de l'interrupteur : " + ", ".join(offenders)

# Un seul cache réseau, et il est piloté par les Réglages.
app = source("Orvian/App/OrvianApp.swift")
assert "URLCache.shared" not in app, "Le doublon de cache réseau doit rester supprimé"
api = source("Orvian/Core/API/APIClient.swift")
assert api.count("URLCache(") == 1, "Un seul URLCache dans le client API"
assert "networkCacheLimitMB" in api
assert "func applyCacheSettings()" in api
settings = source("Orvian/Features/Settings/SettingsView.swift")
assert "networkCacheLimitMB" in settings

# Le cache du filtre ne doit plus vivre dans un @State de la vue.
grid = source("Orvian/Features/Shared/FileGridView.swift")
assert "@State private var visibleItemsCache" not in grid
model = source("Orvian/Features/Shared/FileGridViewModel.swift")
assert "@ObservationIgnored private var visibleItemsCache" in model
assert "revisionBumpPending" in model
assert "snapshotWriteScheduled" in model

# Le préchargement des miniatures reste en temps constant.
thumbnails = source("Orvian/Core/Cache/ThumbnailProvider.swift")
assert "guard seen.insert(key).inserted else { continue }" in thumbnails

# Onglets conservés et pastille flottante.
tabbar = source("Orvian/UI/FloatingTabBar.swift")
assert "var isKeptAlive: Bool" in tabbar
assert "case .home, .favorites, .tag: return true" in tabbar
assert ".animation(Motion.animation(.snappy(duration: 0.25)), value: selection)" in tabbar
main_tabs = source("Orvian/App/MainTabView.swift")
assert "safeAreaInset(edge: .bottom" not in main_tabs, "La pastille ne doit plus pousser la grille"
assert "target.isKeptAlive || target == shell.tab" in main_tabs

# Le titre de la visionneuse se mesure sur le conteneur.
chrome = source("Orvian/UI/MediaChrome.swift")
assert "containerWidth" in chrome
assert "availableWidth" not in chrome

# Le double-tap vidéo diffère la bascule des contrôles.
video = source("Orvian/Features/Viewer/VideoPlayerView.swift")
assert "pendingToggleTask" in video
assert "cancelPendingToggle" not in video

print("Motion and isolation checks passed")
```

- [ ] **Step 2: L'exécuter et le brancher sur la CI**

Run: `python3 .github/scripts/check_motion_and_isolation.py`
Expected: `Motion and isolation checks passed`

Ajouter dans `.github/workflows/build.yml`, après l'étape « Check favorites disk cache » :

```yaml
      - name: Check motion switch and isolation invariants
        run: python3 .github/scripts/check_motion_and_isolation.py
```

- [ ] **Step 3: Relire chaque diff**

Run: `git diff main --stat` puis `git diff main`
Expected: aucun changement hors des fichiers listés ci-dessus ; aucun secret ; aucune modification de `project.yml`.

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/check_motion_and_isolation.py .github/workflows/build.yml
git commit -m "ci: garde lisible sur les invariants d'accessibilité et d'isolation"
```

- [ ] **Step 5: Pousser**

```bash
git push origin main
```

Expected: la CI construit l'IPA et publie une version. Si une étape échoue, corriger localement, `git commit`, `git push` de nouveau.

---

## Self-Review

**1. Couverture de la demande.** Points 2 (T1, T14), 3 (T12), 5 (T10), 6 (T11), 7 (T7), 10 (T5), 11 (T3), 12 (T6), 13 (T4), 15 (T2), 16 (T8), 17 (T9), 18 (T13). Les 13 points demandés ont chacun une tâche. Points 1, 4, 8, 9, 14 : hors périmètre, conformément à la demande.

**2. Analyse de granularité.** Chaque étape est une action vérifiable. Les codes de la spécification (valeurs exactes, signatures, clés de préférences) sont dans le plan ; les choix que le plan ne fixe pas (corps de fonction) sont laissés à l'exécutant.

**3. Cohérence des types.** `Motion.animation(_:) -> Animation?` est produit en T1 et consommé de T2 à T14. `AppTab.isKeptAlive` est produit en T12 et consommé dans le même fichier. `commitListSnapshot()` / `flushPendingSnapshot()` sont produits et consommés en T6. `VisibleItemsKey` / `VisibleItemsCache` passent à interne en T5. `FileCardView.showFileSizes` / `.defaultFolderColor` sont produits en T8 et utilisés dans le même fichier.

**4. Review Focus.** Les cinq entrées sont couvertes : (1) favori annulé → Task 6 Step 3 préserve l'ordre exigé par `FavoritesDiskCacheChecks` et ne publie qu'une révision ; (2) rotation → Task 9 ; (3) réglage du cache en cours d'usage → Task 2 Step 2 (`applyCacheSettings` ne touche pas les requêtes en vol) ; (4) double-tap hors fenêtre → Task 10 Step 2 (la tâche annulée ne s'exécute plus) ; (5) retour sur Favoris après import → Task 6 Step 2 (flush avant lecture).

**5. Proportion.** Le plan est plus long que l'audit mais reste inférieur au code qu'il décrit : aucun corps de fonction n'est écrit pour une simple mechanical edit, seuls les invariants non triviaux (le cache `@State`, le coalescement de révision, la mesure de largeur) sont détaillés.

**Écart assumé.** Le point 15 demande aussi « un réglage pour cette partie, comme il en existe un pour les images ». T2 Step 3 l'ajoute, mais avec une liste de valeurs discrètes plutôt qu'un champ libre, pour rester dans le style du `Picker` existant de `thumbnailCacheLimitMB` et éviter un champ texte à valider.
