# iPad Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adapter les cinq onglets à l’iPad avec une barre latérale masquable sans modifier l’iPhone.

**Architecture:** NavigationSplitView iPad autour des onglets existants ; conserver leurs piles et callbacks. Mesurer la colonne de contenu et transmettre DriveLayout par environnement. Réutiliser les sections existantes pour les écrans en colonnes.

**Tech Stack:** Swift 5, SwiftUI/iPadOS 26, XcodeGen, tests Swift exécutables et tests iOS hébergés.

**Spec:** `docs/superpowers/specs/2026-10-16-ipad-layout-design.md`

## Global Constraints
- Aucun changement de direction artistique ni de dépendances.
- iPhone : conserver barre flottante, densité choisie et disposition actuelles.
- Conserver navigation, défilement, visionneuses, transferts, verrouillage et isolation par session.

## Review Focus
- Redimensionner et masquer la barre sans perdre la navigation ou les données chargées.
- Une fenêtre iPad étroite doit conserver un accès aux cinq onglets.
- Préférences de colonnes existantes inchangées sur iPhone et non réécrites par l’iPad.
- Transferts, import et dernières cartes ne doivent pas se recouvrir après retrait de la barre basse.
- Dynamic Type, VoiceOver, thèmes et réduction de transparence doivent rester natifs.

### Task 1: Métriques et grilles adaptatives
**Files:** `Orvian/UI/DriveLayout.swift`, `Orvian/UI/DesignSystem.swift`, `Orvian/Features/Shared/FileGridView.swift`, `Orvian/Features/Tag/TagsView.swift`, `Tests/DriveLayoutChecks.swift`, `.github/scripts/check_ios_regressions.py`.
**Interfaces:** `DriveLayout(isPad: Bool, width: CGFloat)` ; `fileColumns(preferred: Int)`, `tagColumns(preferred: Int)`, `usesTwoColumns`. Environnement `driveLayout`, iPhone par défaut.
- [x] Écrire et exécuter les tests Swift de densité iPhone, largeur iPad avec/sans barre, fenêtre étroite, préférences limites et seuil de colonnes.
- [x] Implémenter les métriques ; vérifier les tests avec `swiftc -parse-as-library -swift-version 5 Orvian/UI/DriveLayout.swift Tests/DriveLayoutChecks.swift -o <temp>/drive-layout.exe`, puis exécuter le binaire.
- [x] Brancher les grilles et la vérification CI sans modifier les préférences stockées.

### Task 2: Navigation iPad et chrome
**Files:** `Orvian/App/MainTabView.swift`, `Orvian/UI/DesignSystem.swift`, `Orvian/Features/Home/DirectoryView.swift`, `Orvian/Features/Favorites/FavoritesView.swift`, `Tests/iOS/IPadLayoutTests.swift`.
**Interfaces:** Consomme `driveLayout` ; conserve `MainTabShellState` et callbacks sélection/résélection.
- [x] Ajouter les tests hébergés de métriques et documenter le parcours de bascule native.
- [x] Ajouter NavigationSplitView uniquement sur iPad, bouton natif et visibilité liée ; mesurer le détail sans changer son identité lors d’une bascule.
- [x] Réutiliser transferts, préchargement Profil et reset d’onglet ; ajuster les marges iPad et conserver les marges iPhone.

### Task 3: Réglages, Profil et validation
**Files:** `Orvian/Features/Settings/SettingsView.swift`, `Orvian/Features/Profile/ProfileView.swift`, `Tests/IOSRegressionChecklist.md`, `.github/workflows/build.yml`.
**Interfaces:** Consomme `DriveLayout.usesTwoColumns` ; réutilise sections et destinations existantes.
- [x] Réutiliser les mêmes réglages et sections en colonnes larges, avec repli étroit ; ne pas modifier les chargements réseau.
- [x] Ajouter la checklist iPad (masquage, portrait, fenêtre étroite, accessibilité, transferts, verrouillage, iPhone) et exécuter les tests Python et Swift disponibles.
- [x] Revue finale du diff ; signaler explicitement que Windows ne permet ni build Xcode ni tests de rendu iOS.

## Exécution
- Autorisation de commencer reçue dans la conversation ; exécution directe dans cette session, branche `feat/ipad-layout`. L’utilisateur a ensuite demandé un push sur main et la surveillance de GitHub Actions.
- Les fichiers locaux préexistants `.model-tools/`, `model-cache/` et `.superpowers/` restent intacts.
- Validation de rendu et compilation iOS à effectuer sur macOS/simulateur ; les tests Swift purs peuvent s’exécuter sous Windows.
- Tests Swift purs : RED (DriveLayout absent), puis GREEN sous Windows. Les tests hébergés sont branchés à la CI mais ne peuvent pas être exécutés localement.
- Suite Python complète : 29 tests passent. (Historique : la version 0.16.2 a ensuite supprimé la détection d'images et le modèle Core ML.)
- Vérification dédiée : les 29 tests Python hors conversion du modèle passent ; analyse syntaxique de tous les fichiers Swift modifiés réussie (`swiftc -frontend -parse`). Cela ne constitue pas un build iOS.
- Revue indépendante demandée sur l’ensemble du diff non commité. Les essais de rendu, de bascule et d’accessibilité de la checklist restent à réaliser sur iPad/simulateur.
- Revue indépendante terminée : un problème important de conservation de l’espace Réglages corrigé en utilisant un chemin typé unique possédé par la session, partagé entre détail large et pile compacte. Reset et changements d’onglet testés avec le véritable TabNavigationState (dépendances SwiftUI remplacées uniquement dans le harnais de test). Échec sur l’ancienne interface, puis exécution réussie avec le chemin typé ; test hébergé ajouté aussi à la CI. Aucun autre problème confirmé par le reviewer.
- Première exécution GitHub Actions : compilation et tests hébergés iOS réussis ; le contrôle anti-décalage a refusé l’inset dynamique des transferts iPad. Correction : superposition avec marge statique basse, et espace à droite pour le bouton d’import. Le contrôle existant est conservé sans assouplissement.
