# Folder Image Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter un bouton « Scanner ce dossier » classant les images directement présentes dans le dossier ouvert, avec filtres SFW / NSFW / Non analysés.

**Architecture:** Un coordinateur observable énumère la source `.directory(directoryId)` indépendamment de la grille et classe ses images séquentiellement. Un actor Core ML / Vision produit les probabilités ; un store observable conserve les scores isolés par compte et publie des instantanés pour le filtrage commun de la grille et de la visionneuse.

**Tech Stack:** Swift 5, SwiftUI / Observation, Foundation, Core ML, Vision, iOS 26, XcodeGen. Python / coremltools pour ajouter softmax au package Core ML amont épinglé, hors du runtime de l'app. Les poids et le réseau de classification sont conservés.

**Spec:** `docs/superpowers/specs/2026-10-06-folder-image-classification-design.md`.

## Global Constraints

- Un bouton dédié lance le scan dans le dossier actuellement ouvert. Les images restent affichées normalement.
- Toutes les pages du dossier sont parcourues, y compris celles qui ne sont pas encore chargées à l'écran. Les sous-dossiers ne sont pas parcourus.
- Un seul scan est actif à la fois dans l'app ; la concurrence d'inférence initiale est de un.
- Le scan s'arrête si l'app passe en arrière-plan ou si le compte actif change.
- Les résultats déjà obtenus restent disponibles après une annulation.
- Une image sans résultat valide, y compris après un échec, reste « Non analysée ».
- Le seuil est réglable, avec une valeur initiale de 0,80 à valider ; changer le seuil reclasse les scores sans inférence.
- Le modèle est embarqué avec l'app. Aucun service de classification distant n'est ajouté.
- Les GIF sont représentés par une seule image fixe. Aucune analyse vidéo ou récursion.
- Le poste Windows ne possède pas Xcode ou swiftc : les checks Swift et la compilation sont exécutés sur macOS ; ne pas déclarer une compilation native vérifiée par une simple inspection statique.

## Review Focus

1. Scores bruts pris pour des probabilités : le modèle exporté inclut softmax, avec comparaison au modèle de référence (tâche 1).
2. Remplacement d'une image avec un identifiant conservé : invalider le score et récupérer des octets frais, sans réutiliser une ancienne miniature (tâches 2 et 3).
3. Dossier multipage avec uniquement des sous-dossiers sur une page : poursuivre le curseur mais ne demander aucun contenu de sous-dossier (tâche 3).
4. Annulation / changement de compte pendant un await : vérifier la génération et le compte avant chaque publication tardive (tâche 3).
5. Résultats arrivant pendant un filtre actif ou une visionneuse ouverte : réviser le cache visible et conserver une sélection valide (tâche 4).

## Fichiers et responsabilités

- `Orvian/Core/Classification/ImageClassification.swift` : révision du contenu, score, snapshot et politique de seuil, sans dépendances UIKit / Vision.
- `Orvian/Core/Classification/ImageClassificationStore.swift` : cache mémoire / disque observable et isolation par compte.
- `Orvian/Core/Classification/NSFWImageClassifier.swift` : actor de chargement et inférence du modèle, avec un nom distinct de la classe générée pour le modèle.
- `Orvian/Core/Classification/FolderImageScanner.swift` : coordinateur, pagination, progression et annulation.
- `Orvian/Features/Shared/FolderScanSheet.swift` : progression, seuil, annulation et résumé.
- `Orvian/Resources/NSFWClassifier.mlpackage/` : modèle réel compilé par Xcode ; jamais une simple référence Git LFS.
- `scripts/nsfw/convert_model.py`, `scripts/nsfw/verify_model.py`, `scripts/nsfw/requirements.txt`, `scripts/nsfw/model-manifest.json` : conversion reproductible et origine du modèle.
- `Orvian/Resources/NSFW-MODEL-NOTICE.md` : attribution Apache 2.0 du modèle et MIT du script si adapté.
- Modifications ciblées : `ThumbnailProvider.swift`, `FileFilters.swift`, `FilterMenu.swift`, `DirectoryView.swift`, `FileGridView.swift`, `FileGridViewModel.swift`, `MediaPagerView.swift`, `SessionStore.swift`, `OrvianApp.swift`, `project.yml`, checks / CI et README.
- `HomeTab.swift` réutilise déjà `DirectoryView` au démarrage : pas de seconde implémentation de bouton.

## Tâche 1 : modèle embarqué produisant des probabilités

**Files:** créer les scripts `scripts/nsfw/`, le package et sa notice ; adapter `project.yml` si nécessaire ; créer `Tests/iOS/NSFWClassifierTests.swift` et `Orvian/Core/Classification/NSFWImageClassifier.swift`.

**Interfaces:** actor `NSFWClassifier`, `func prepare() async throws`, `func classify(imageData: Data) async throws -> Float` ; le Float retourné est la probabilité de la classe NSFW, jamais la confiance de la classe gagnante.

- [ ] Écrire `testBundledModelProducesNormalizedProbabilities` : une image RGB synthétique doit produire les classes NSFW / SFW, des scores finis dans `[0,1]` et une somme à moins de `0.001` de un. Écrire `testUnreadableImageThrows`.
- [ ] Exécuter les tests iOS sur macOS et constater l'échec en l'absence de service / modèle.
- [ ] Adapter la conversion à partir du commit NSFWScanner `c8ff10d90d80e3d4f65d75b9a745a529c2defb78` : wrapper PyTorch incluant `softmax(dim=-1)`, `ct.target.iOS16`, FP16, entrée `image` RGB `(1,3,384,384)`, scale `1/127.5`, bias `[-1,-1,-1]`, classes dans l'ordre du config Marqo `NSFW, SFW`.
- [ ] Résoudre et figer la révision Hugging Face, les dépendances compatibles et les checksums du package dans le manifeste pendant la conversion. Le poids upstream vu dans Git LFS fait 11 205 248 octets, SHA-256 `25f0a6ee9ddd1c5756a87f3fc61e5c0ae40e3803a36b890369a47b372079ce2d` : ne pas confondre ce pointeur de 133 octets avec le poids réel.
- [ ] Implémenter le service : modèle compilé `.mlmodelc` chargé une fois, `MLModelConfiguration.computeUnits = .all`, une nouvelle `VNCoreMLRequest` par image, orientation ImageIO et `.centerCrop`. Extraire explicitement NSFW et vérifier les deux scores ; throw si sorties absentes / invalides. Les inférences restent sur l'actor, hors du MainActor.
- [ ] Comparer Core ML et PyTorch sur les mêmes pixels prétraités (noir, blanc, gradient et image de référence SFW) : mêmes labels, écart absolu maximal par classe `< 0.01`, toute différence hors tolérance échoue. Ajouter une vérification Vision sur une image non carrée / orientée. La comparaison exacte des pixels sépare les erreurs de conversion des différences de rééchantillonnage.
- [ ] Vérifier `python3 scripts/nsfw/verify_model.py`, puis `xcodegen generate` et les tests `NSFWClassifierTests` sur un simulateur iOS disponible. Le modèle doit être réellement présent dans le bundle et compilable pour iOS.
- [ ] Commit autonome : `feat: bundle verified on-device NSFW classifier`.

## Tâche 2 : scores locaux, révisions et seuil

**Files:** créer `ImageClassification.swift`, `ImageClassificationStore.swift`, `Tests/ImageClassificationChecks.swift` et `.github/scripts/check_image_classification.py`.

**Interfaces:** `ImageContentRevision: Codable, Hashable, Sendable` avec `size`, `lastModifiedAt`, `updatedAt` ; initialiseur `init?(file: DriveFile)` refusant les fichiers sans date de révision exploitable. `ImageClassificationRecord: Codable, Sendable` conserve probabilité, révision, version du modèle et date. `ImageClassificationSnapshot: Sendable` expose `func score(for fileID: Int) -> Float?` et `init(scores: [Int: Float] = [:])`.

Le store est `@MainActor @Observable`, avec `static let shared`, `private(set) var revision: Int`, `var threshold: Float` initialement `0.80`, `func snapshot(driveId: Int, items: [DriveFile]) -> ImageClassificationSnapshot`, `func load(credentialFingerprint: String) async`, `func record(score: Float, file: DriveFile, driveId: Int, credentialFingerprint: String, modelVersion: String) async throws`, et `func resetSession()`.

- [ ] Écrire les assertions : `0.79` donne SFW, `0.80` NSFW ; absence / NaN / infini / score hors `[0,1]` ne donne jamais SFW ; les révisions de contenu différentes ne partagent aucun score.
- [ ] Compiler ces checks contre les types de production via le script Python, comme les checks Swift existants ; constater l'échec avant implémentation.
- [ ] Implémenter les types et le store. Namespace disque SHA-256 de l'empreinte du compte, drive / fichier, JSON atomique dans Application Support exclu des sauvegardes ; IO hors MainActor, chargement et écritures groupés, limite de 20 000 entrées persistantes par compte avec éviction des plus anciennes. Révision incrémentale sur chargement, résultat, seuil ou reset.
- [ ] Réutiliser un score seulement si le modèle et la révision du fichier correspondent. Une image sans date peut recevoir un résultat de session mais ne fournit aucun score persisté réutilisable au prochain lancement.
- [ ] Ajouter tests iOS du store dans `Tests/iOS/ImageClassificationStoreTests.swift` avec répertoire temporaire injectable : aller-retour disque, isolation de deux comptes / drives, même ID modifié, fichier JSON corrompu, reset pendant lecture différée, seuil changé sans classifieur.
- [ ] Exécuter `python3 .github/scripts/check_image_classification.py` et les tests iOS du store sur macOS ; attendre succès.
- [ ] Commit autonome : `feat: persist revision-scoped image classification scores`.

## Tâche 3 : scan du seul dossier courant

**Files:** créer `FolderImageScanner.swift` et `Tests/iOS/FolderImageScannerTests.swift` ; adapter `ThumbnailProvider.swift`.

**Interfaces:** `@MainActor @Observable final class FolderImageScanner` possède `static let shared`, `private(set) var progress: FolderScanProgress?`, `func start(driveId: Int, directory: DriveFile)`, `func cancel()`, `func resetSession()` ; `FolderScanProgress` expose le nom / ID du dossier, phase, total optionnel, processed, sfw, nsfw, failed, reused et message d'erreur. Les dépendances async sont injectables par closures : `(Int, Int, String?) async throws -> CursorPage<DriveFile>`, `(Int, Int) async throws -> Data`, `(Data) async throws -> Float`, `() async throws -> Void` pour préparer le modèle, et fournisseur de l'empreinte courante.

ThumbnailProvider ajoute `func classificationImageData(driveId: Int, fileId: Int) async throws -> Data` : octets frais via `KDriveService.thumbnailData`, throttle existant, contrôle du compte avant / après l'await, sans lire les anciens caches d'image.

- [ ] Écrire `testScansOnlyDirectImagesAcrossEveryPage` : trois pages, une page de sous-dossiers uniquement, doublon d'image, image GIF et vidéo. Toutes les requêtes portent le dossier initial ; aucun ID de sous-dossier n'est énuméré, seules les images distinctes sont classées.
- [ ] Écrire `testRepeatedCursorIsIncomplete`, `testPageFailureIsNotSuccess`, `testImageFailureContinues`, `testEmptyFolder`, `testCancellationRejectsLateResult`, `testAccountChangeRejectsLateResult`, `testSecondStartDoesNotDuplicate`, `testRescanReusesOnlyMatchingRevisions`. Utiliser des continuations contrôlées pour les courses, sans sleeps.
- [ ] Exécuter les tests et constater les échecs initiaux, puis implémenter : capture du compte et du dossier, énumération complète avec `forceNetwork: true`, curseurs déjà vus, dédoublonnage, vérifications de cancellation / génération / compte autour de chaque await. Inference séquentielle et cache de scores avant téléchargement.
- [ ] Préparer le modèle avant de télécharger les images via `prepare()`, avec erreur globale lisible si indisponible ; une panne sur une image est comptabilisée et les suivantes continuent. Attendre la persistance des résultats avant d'annoncer la fin.
- [ ] Les compteurs de classes sont recalculés à partir des scores quand le seuil change ; le résumé distingue résultats réutilisés, nouvelles analyses et échecs. Une interruption conserve les résultats déjà enregistrés.
- [ ] Exécuter `FolderImageScannerTests` et les checks existants de concurrence ; attendre succès.
- [ ] Commit autonome : `feat: scan all direct images in the current folder`.

## Tâche 4 : filtres partagés et invalidation des vues

**Files:** adapter `FileFilters.swift`, `FilterMenu.swift`, `FileGridView.swift`, `FileGridViewModel.swift`, `MediaPagerView.swift`, `Tests/FileFiltersChecks.swift`, `.github/scripts/check_ios_regressions.py`.

**Interfaces:** ajouter `FileFilters.ClassificationFilter` (`all`, `sfw`, `nsfw`, `unscanned`) et `var classification: ClassificationFilter = .all`. Ajouter à `visible` les arguments finaux `classification: ImageClassificationSnapshot = .init()` et `nsfwThreshold: Float = 0.80`. Ajouter `classificationRevision: Int` à `VisibleItemsKey`. Injecter le store dans `visibleItems(key:mediaMetadata:classificationStore:)` et `VisibleItemsCache.visibleItems(key:items:mediaMetadata:classificationStore:)`.

- [ ] Étendre les checks existants : SFW / NSFW / inconnu, seuil exact, intersection recherche / tri, absence de dossiers / vidéos sous filtre de classification, `.all` inchangé, `isActive` et reset. Vérifier que les anciennes invocations sans arguments nouveaux continuent de compiler.
- [ ] Exécuter `python3 .github/scripts/check_ios_regressions.py` sur macOS pour constater l'échec, puis implémenter les filtres. Les Bindings du menu centralisent le couplage : classification active implique Images et retire orientation / 4K ; type autre qu'Images remet la classification à `.all`.
- [ ] Publier le chargement du store au niveau des vues de grille ; comparer la révision du store dans la clé de mémoïsation et les tâches de calcul. La révision ne modifie pas la pagination serveur ni son tri.
- [ ] Fournir le même snapshot / seuil à toutes les passes de `MediaPagerView`, y compris son diagnostic de médias non résolus. À chaque nouvelle révision, refaire la sélection ; si le fichier sélectionné disparaît du filtre, choisir un survivant ou afficher l'état vide existant.
- [ ] Ajouter tests iOS vérifiant l'invalidation du cache visible pour un nouvel instantané et pour un seuil modifié ; vérifier manuellement le pager pendant un scan.
- [ ] Exécuter les checks de filtres et les checks iOS existants ; attendre succès.
- [ ] Commit autonome : `feat: filter image grids and viewer by local classification`.

## Tâche 5 : bouton, progression, cycle de vie et validation finale

**Files:** créer `FolderScanSheet.swift` ; adapter `DirectoryView.swift`, `OrvianApp.swift`, `SessionStore.swift`, `Tests/IOSRegressionChecklist.md`, `.github/workflows/build.yml`, `README.md`.

**Interfaces:** `struct FolderScanSheet: View` reçoit le coordinateur et le store observables ; `DirectoryView` possède uniquement son booléen de présentation et un bouton dédié, nommé pour VoiceOver « Scanner ce dossier ».

- [ ] Ajouter tests de lifecycle du scanner : `cancel()` sur passage en arrière-plan, `resetSession()` avant suppression / remplacement du token ; aucune publication tardive après reset. Intégrer les nouveaux checks dans la CI avant la compilation iOS.
- [ ] Implémenter le bouton dans la toolbar de `DirectoryView`, hors mode sélection. Capturer `directory` et `driveId`, appeler `start`, ouvrir la feuille immédiatement ; si un autre scan est actif, montrer son dossier / progression sans le remplacer. Le même composant couvre le dossier de démarrage.
- [ ] Implémenter la feuille : « Recherche des images », puis `processed / total`, résultats et erreurs, Slider de seuil `0.50...0.99` avec pas `0.01`, « Annuler » et fermeture. Fermer la feuille conserve le scan tant que l'app reste au premier plan.
- [ ] Brancher le cycle de vie au niveau de l'app, pas de la vue de dossier : arrière-plan annule ; les chemins de connexion / déconnexion réinitialisent le scanner avant de changer les credentials. Le filtre reste utilisable à partir des résultats enregistrés.
- [ ] Documenter dans README le scan direct, les GIF fixes, les téléchargements kDrive, les résultats propres à l'appareil et la précision non garantie ; compléter la checklist de vérification sur iPhone.
- [ ] Exécuter sur macOS les checks existants (`check_concurrency.py`, `check_performance_regressions.py`, `check_favorites_cache.py`, `check_motion_and_isolation.py`, `check_ios_regressions.py`, `check_audit_regressions.py`), le nouveau check et les tests iOS. Générer puis compiler avec la commande `xcodebuild` actuelle pour `generic/platform=iOS`.
- [ ] Contrôler la présence du `.mlmodelc` dans l'app générée et tester sur iPhone : dossier multipage, bouton / annulation, dossier vide, changement de compte, navigation pendant le scan, mémoire / latence et miniatures représentatives. Rapporter séparément toute vérification matérielle restant indisponible.
- [ ] Exécuter `git diff --check`, relire le diff complet, puis commit autonome : `feat: expose current-folder scan and classification filters`.

## Exécution proposée

Exécution native dans cette conversation, tâches successives avec leurs vérifications : les composants partagent plusieurs contrats et ne justifient pas de multiplier les contextes. Une revue indépendante du changement complet suit les vérifications, conformément à la compétence d'exécution choisie. Aucun push sur `main` n'est nécessaire pour préparer la fonctionnalité : ce dépôt publie automatiquement un IPA sur chaque push de `main`.

Le plan doit être revu et la méthode d'exécution choisie avant les modifications du produit. Aucun fichier Swift ou modèle n'a été modifié pendant cette préparation.
