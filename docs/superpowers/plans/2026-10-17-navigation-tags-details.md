# Navigation, tags et Détails — Implementation Plan

**État d'exécution :** implémentation directe achevée, revue indépendante et correctifs
consignés dans `2026-10-17-navigation-tags-details-progress.md`. Vérifications natives
SDK/appareil non exécutables sous Windows. La demande ultérieure de l'utilisateur
interdit les vérifications visuelles et captures GitHub Actions : elle remplace les
étapes de captures proposées dans ce plan. Push final explicitement autorisé.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Track steps with checkboxes.

**Goal:** Restaurer les commandes protégées, corriger Favoris, ajouter listes iPad et intersections de tags, remplacer Détails par un inspecteur informatif.
**Architecture:** Conserver le modèle paginé partagé et ses mutations. Donner aux navigateurs et présentations une source synchrone commune d'éléments visibles, puis ajouter une source d'intersection normalisée et un inspecteur natif adaptatif. Ne pas créer un second système de navigation ou d'upload.
**Tech Stack:** SwiftUI/UIKit, Swift 5, iOS 26, XCTest et contrôles Swift/Python existants ; aucune nouvelle dépendance.
**Spec:** `docs/superpowers/specs/2026-10-17-navigation-tags-details-design.md`, validée dans la conversation.

## Global Constraints
- Ordre : Réglages — Tags — Accueil — Favoris — Profil, sur toutes les présentations.
- Hasard puis Sélectionner : deux boutons séparés, ensemble en haut à droite dans les navigateurs concernés ; modification ultérieure sur autorisation explicite uniquement.
- Trois colonnes maximum sur iPhone ; six niveaux de densité iPad conservés.
- Intersection AND, fichiers et dossiers, mise à jour à chaque sélection, Terminer conserve le résultat.
- Détails en lecture seule : aucune opération ni menu d'opérations ; fermeture et reprise de chargement seulement.
- Préserver les confirmations destructives, droits, annulations et isolation compte/drive.
- Aucun push automatique, aucune nouvelle dépendance. Ne pas annoncer de build iOS sous Windows.

## Review Focus
- Cache déjà chargé puis nouvelle révision : les boutons doivent suivre exactement la population visible, sans rapport périmé.
- Première page sans intersection et réponse tardive d'un ancien filtre : poursuivre la pagination sans publier les mauvais résultats.
- Tag actif supprimé : signaler le filtre devenu invalide, ne pas élargir silencieusement l'intersection.
- Inspecteur ouvert puis redimensionnement, changement de fichier ou de compte : présentation et données cohérentes, aucune fuite.
- Anciennes préférences de densité élevées : migration iPhone à 2–3 sans écraser le choix iPad.

## Carte des fichiers
- `Orvian/UI/FloatingTabBar.swift`, `App/IPadTabView.swift`, `Features/Profile/ProfileView.swift` : ordre et intitulés protégés.
- `Features/Shared/FileGridViewModel.swift`, `FileGridView.swift`, `Home/DirectoryView.swift`, `Favorites/FavoritesView.swift`, `Tag/TagsView.swift` : données visibles, commandes et présentations.
- Nouveau `Features/Shared/BrowserToolbar.swift` : paire de commandes protégées et bascule iPad, sans état de sélection parallèle.
- Nouveau `Models/FilePresentation.swift`, `UI/IPadLayout.swift`, `Features/Settings/SettingsView.swift` : préférences et limites de densité.
- Nouveau `Features/Shared/FileListRow.swift` : ligne détaillée, opérations existantes réutilisées.
- Nouveau `Models/TagIntersection.swift`, `Core/API/KDriveService.swift`, `KDriveService+Files.swift`, `FileSource+Ordering.swift`, `Core/Cache/DirectoryListStore.swift`, `FavoritesDiskCache.swift`, `Features/Shared/FileGridMutationCenter.swift` : portée, chargement et invalidation des intersections. Ne modifier les caches que si leur représentation de source l'exige.
- `App/TabNavigationState.swift`, `Features/Tag/TagsView.swift` et nouveau `Features/Tag/TagIntersectionView.swift` : sélection et navigation du croisement.
- `Features/Shared/FileDetailSheet.swift`, nouveau `FileDetailsViewModel.swift`, `FileGridView.swift`, `Core/Media/MediaMetadataStore.swift` : fiche informative et inspecteur ; étendre le store uniquement pour des métadonnées réellement accessibles et nécessaires.
- `AGENTS.md`, tests et scripts existants : garde-fous durables, tests et vérification CI.

## Lot 1 — Commandes, Favoris et densité

### Task 1: Source commune des éléments visibles et commandes

**Interfaces:** Ajouter `VisibleFileSnapshot` avec `key: VisibleItemsKey` et `items: [DriveFile]`. Ajouter au modèle `visibleSnapshot(filters: FileFilters, searchText: String, foldersFirst: Bool) -> VisibleFileSnapshot`, réutilisant le cache et le store de métadonnées existants. La clé doit contenir toutes les entrées actuellement prises en compte par `VisibleItemsKey` ; la recherche serveur ne doit pas être réappliquée localement.

- [ ] Écrire un test reproduisant l'invalidation du rapport Favoris lors d'une révision avant la mise à jour du parent ; démontrer que des fichiers visibles peuvent laisser les commandes inactives. Exécuter ce test et constater l'échec.
- [ ] Ajouter des tests de population après cache, rechargement, recherche, filtres, tri, pagination, et retrait d'un favori. Vérifier : Hasard exclut les dossiers, Sélectionner les inclut, une liste vide désactive les deux.
- [ ] Implémenter l'instantané et faire dériver directement les commandes et cellules de cette même source. Retirer les rapports devenus inutiles et adapter tous leurs appelants ; ne pas assouplir les gardes de session.
- [ ] Extraire `BrowserToolbar` avec `canOpenRandom: Bool`, `canSelect: Bool`, `onRandom: () -> Void`, `onSelect: () -> Void`. Déclarer les deux ToolbarItems en haut à droite, Hasard avant Sélectionner, hors menu.
- [ ] Brancher Accueil, Favoris et `CategoryFilesView` ; pour un tag, réutiliser les opérations de sélection des navigateurs plutôt que dupliquer des mutations réseau. Toute extraction commune doit garder les mêmes confirmations et résultats partiels.
- [ ] Tester la mise à jour d'une sélection après disparition d'un élément et un changement de filtre pendant un chargement. Ajouter des tests hébergés des boutons avec données réelles de fixture, pas seulement des recherches de chaînes.
- [ ] Exécuter `python -m unittest discover -s Tests -p "test_*.py"` et les contrôles Swift d'audit ; adapter les contrats de sources uniquement pour les comportements intentionnellement remplacés.

### Task 2: Navigation protégée et préférences iPhone

**Interfaces:** `AppTab.presentationOrder` devient l'ordre approuvé. `FilePresentation` est un enum Codable/RawRepresentable `grid` / `list`. Clés de présentation : `homeFilePresentation`, `favoritesFilePresentation`, `tagFilePresentation`. Densité : `phoneFileGridColumns` et `padFileGridDensity`, initialisées depuis l'ancienne clé `fileGridColumns` sans l'écraser.

- [ ] Écrire et exécuter les tests qui attendent l'ordre `[.settings, .tag, .home, .favorites, .profile]`, le titre Profil et l'absence du menu regroupant Hasard/Sélectionner : vérifier l'échec avant de modifier les sources.
- [ ] Écrire un test de migration pour les anciennes valeurs 0, 2, 3, 4 et 7 : iPhone limité à 2–3, iPad à 2–7, aucun écrasement d'un réglage déjà migré. Tester également le grand texte et la géométrie inconnue.
- [ ] Adapter les trois barres, le titre Profil et les références visibles à Activité. Préserver les clés sérialisées des onglets et leur navigation.
- [ ] Adapter réglages et grilles : Stepper iPhone 2...3, densité iPad 2...7 ; conserver la réduction automatique en texte accessible et panneau étroit.
- [ ] Créer `AGENTS.md` documentant les choix protégés et l'exigence d'autorisation explicite ; ajouter des tests d'ordre commun aux barres et à la paire de commandes.
- [ ] Exécuter le runner `check_adaptive_ui.py`, les tests Python et les tests hébergés disponibles en CI. Ne pas committer/pousser automatiquement en l'absence de demande.

## Lot 2 — Listes et croisement de tags

### Task 3: Deux présentations, une population

**Interfaces:** `FileGridView` accepte `presentation: FilePresentation = .grid`. La présentation ne change ni source, ni pagination, ni ordre. `FileListRow` consomme les mêmes fichiers et intentions que les cartes ; mutualiser le code de menu/activation si nécessaire, sans second ensemble d'opérations.

- [ ] Ajouter des tests de restauration indépendante des trois clés de présentation et de parité des identifiants liste/grille, après recherche et pagination. Vérifier l'échec avant implémentation.
- [ ] Ajouter le rendu LazyVStack des lignes : miniature, nom, type, taille, modification et tags ; aucun poids fictif pour un dossier, aucune requête de fiche par ligne.
- [ ] Adapter les colonnes à la largeur disponible : nom jamais masqué, détails secondaires réduits en fenêtre étroite ; état sélectionné et menus identiques à la grille, cibles >=44 pt.
- [ ] Ajouter le bouton liste/grille iPad dans Accueil, Favoris et fichiers des Tags. Transmettre le choix aux sous-dossiers depuis leurs racines sans modifier celui d'un autre onglet.
- [ ] Ajouter la bascule catalogue de tags iPad en réutilisant `CategoryLayout`, séparée du choix de présentation des fichiers ; conserver les contrôles iPhone existants.
- [ ] Tester bascule en cours de sélection, ouverture aléatoire, menu Détails et chargement suivant en liste. Exécuter la suite et prévoir les captures natives en fenêtres large/compacte.

### Task 4: Source d'intersection paginée

**Interfaces:** `TagIntersection: Hashable` normalise `ids: [Int]` à partir de `init(_ ids: Set<Int>)`, triés sans doublons ; `matches(_ membership: Set<Int>) -> Bool` vérifie une intersection AND non vide. Ajouter `FileSource.intersection(TagIntersection)` et `KDriveService.intersectionPage(_:driveId:cursor:forceNetwork:) async throws -> CursorPage<DriveFile>`. Les tris autorisés suivent la recherche par catégorie existante.

- [ ] Écrire et exécuter les tests de normalisation, 0/1/plusieurs tags, fichiers et dossiers, sans héritage des tags des parents. Vérifier leur échec avant implémentation.
- [ ] Vérifier la spécification API locale du serveur ; n'utiliser une intersection serveur que si AND est explicitement garanti. Sinon paginer un tag d'ancrage déterministe et filtrer les appartenances complètes.
- [ ] Écrire les tests de pages sans résultat suivies d'une correspondance, fin de pagination, appartenance manquante puis erreur, annulation et changement de combinaison/compte. Les réponses périmées ne doivent jamais être publiées.
- [ ] Implémenter la source dans les switch exhaustifs (rechercher tous les cas FileSource avant édition), compléter les appartenances uniquement quand elles manquent avec concurrence bornée et contrôle de session après suspension.
- [ ] Adapter les clés de cache, règles d'ordre, états vides et mutations. Les ajouts/retraits de tags doivent faire entrer/sortir les éléments sans réutiliser l'état d'une autre combinaison.
- [ ] Tester le passage d'un élément absent à présent après ajout d'un tag, et l'inverse ; tester des identifiants identiques dans deux comptes/drives. Exécuter les tests Swift de logique et la suite existante.

### Task 5: Sélection multiple et résultats croisés

**Interfaces:** Ajouter à `TabNavigationState` un état de croisement contenant `selectedIDs: Set<Int>`, `isEditing: Bool` et l'état invalide d'un tag supprimé. Il appartient au shell de session, sans AppStorage. `TagIntersectionView` consomme la source Task 4 et le navigateur Task 1/3.

- [ ] Écrire et exécuter les tests : zéro tag ne lance pas un chargement global ; Terminer conserve les IDs ; Effacer les supprime ; changement d'onglet les conserve ; nouveau shell les réinitialise.
- [ ] Placer le bouton croisé à gauche d'Ajouter/Réarranger sur iPad et à gauche de Liste/Grille sur iPhone. En mode édition, le toucher coche au lieu de naviguer.
- [ ] Afficher immédiatement les résultats de chaque sélection ; annuler la tâche précédente et afficher l'état de chargement sans rendre les anciens résultats actionnables.
- [ ] Ajouter noms des tags actifs, Modifier, Terminer et Effacer. En largeur régulière : sélection à gauche, résultats à droite ; en compact : navigation vers les résultats avec retour à la sélection conservée.
- [ ] Réutiliser Hasard/Sélectionner séparés et le choix de présentation Tags. Un dossier ouvert depuis le résultat suit la navigation habituelle ; ses enfants ne sont pas implicitement filtrés par les tags du parent.
- [ ] Tester la suppression d'un tag actif : message explicite et filtre invalide, pas d'élargissement automatique. Tester réseau lent/erreur/reprise et réponse tardive, puis la suite complète.

## Lot 3 — Inspecteur Détails et vérification

### Task 6: Données et fiche informative

**Interfaces:** `FileDetailsViewModel` (@MainActor @Observable) expose le fichier courant, catégories, métadonnées disponibles et erreurs par section ; `load(file: DriveFile, driveId: Int, isTrashed: Bool) async` invalide les demandes précédentes. `FileDetailSheet` conserve son nom de fichier mais son initialiseur devient `init(file:driveId:isTrashed:)`, sans callbacks de mutation/ouverture.

- [ ] Écrire les tests de génération de chargement, changement de compte, corbeille, champs absents et erreur partielle ; conserver les informations déjà connues si une section échoue. Vérifier l'échec avant implémentation.
- [ ] Réutiliser les catégories/chemin fournis et les caches de métadonnées. Étendre les données média seulement si nécessaires et accessibles sans télécharger le média entier ; ne pas déduire des dimensions à partir d'une miniature recadrée.
- [ ] Remplacer entièrement la fiche : en-tête compact miniature/nom/type/taille/favori non interactif, repères dates/média, tags et emplacement. Utiliser les couleurs/arrondis de DS, sans grande vignette ni dégradé décoratif ni lignes de valeurs fictives.
- [ ] Supprimer les opérations et leurs états/alertes de cette fiche, pas les actions contextuelles des éléments. Textes sélectionnables, champs longs lisibles, fermeture explicite et Réessayer par section si nécessaire.
- [ ] Remplacer la présentation Détails du navigateur par `.inspector(isPresented:content:)` natif : colonne à droite en taille régulière, feuille native en compact. Largeur cible 360 pt, adaptée au système, sans deuxième état de présentation concurrent. La documentation Apple confirme cette adaptation native.
- [ ] Tester le remplacement du fichier dans l'inspecteur, renommage/suppression pendant l'ouverture, rotation et redimensionnement sans fiche fantôme ; vérifier le verrouillage et le changement de drive.
- [ ] Ajouter les tests hébergés/captures des états complet, partiel, erreur et corbeille, clair/sombre et texte accessible. Exécuter les suites de régression.

### Task 7: Revue intégrée et publication séparée

- [ ] Étendre `Tests/IOSRegressionChecklist.md` et les jobs existants avec les nouvelles suites de logique et hébergées ; inclure iPhone et iPad 12,9 pouces ou format logique équivalent 1024×1366.
- [ ] Exécuter `python -m unittest discover -s Tests -p "test_*.py"`, `check_adaptive_ui.py`, `check_motion_and_isolation.py`, `check_performance_regressions.py`, `check_recent_sharing.py` et `check_audit_regressions.py`. Exécuter les nouveaux contrôles logiques ajoutés aux tâches précédentes.
- [ ] Sous Windows, vérifier la syntaxe Swift des sources et indiquer séparément les contrôles bloqués par le SDK/cible macOS. Sous macOS : XcodeGen et tests Xcode complets iPhone/iPad, puis scénarios de la checklist.
- [ ] Faire relire le diff complet indépendamment contre la spécification, corriger les défauts importants et relancer les suites concernées.
- [ ] Mettre à jour ce plan avec résultats exacts, limites et captures disponibles. Rendre les changements à l'utilisateur ; aucun commit/push automatique sur main.

## Auto-relecture du plan

Chaque section de la spécification est couverte : commandes/Favoris (1), navigation
et densité (2), présentations (3), intersection backend et UI (4–5), Détails (6),
validation et protections (2 et 7). Les cinq risques Review Focus ont des tests
dans leurs tâches respectives. Les seuils et détails visuels non fixés sont laissés
à l'implémentation ; aucune nouvelle fonctionnalité cloud n'est ajoutée.
