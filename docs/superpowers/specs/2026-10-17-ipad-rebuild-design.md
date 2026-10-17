# Refonte iPad 13 pouces depuis la base antérieure

Statut : direction et implémentation approuvées par l'utilisateur le 17 octobre 2026. La nouvelle interface est codée depuis la base restaurée. Le contrôle préalable GitHub Actions 39013332197 confirme la compilation, les tests iPhone et les dix tests iPad sur iPad Pro 13 pouces (M5), iPadOS 26.4.1. Les essais avec un compte réel restent à réaliser. La conception détaillée est consignée dans `tasks/plan.md` ; les tâches sont suivies dans `tasks/todo.md`.

## Objectif

Reconstruire une interface iPad sobre, lisible et ergonomique en repartant de `3387c1e` (sources de la version 0.16.1), avant l'adaptation iPad de la version 0.16.2. Ne pas corriger progressivement cette ancienne adaptation ni reprendre son conteneur de navigation global.

L'utilisateur signale des plantages à l'ouverture de dossiers, des favoris absents, des commandes Filtre / Recherche / Sélection dupliquées et une navigation qui se dégrade après plusieurs changements d'onglet.

### État vérifié avant reconstruction

- Les 152 fichiers présents dans `Orvian/`, `Tests/` et les deux fichiers CI concernés à la révision de référence correspondent à nouveau à cette révision, après normalisation des fins de ligne.
- Les quatre fichiers ajoutés pour l'ancienne adaptation sont retirés : `DriveLayout.swift`, `DriveLayoutChecks.swift`, `SettingsNavigationChecks.swift` et `IPadLayoutTests.swift`.
- Les 29 tests Python hors outillage du modèle passent localement.
- `project.yml` et `repo.json` conservent les métadonnées de la publication existante. Aucune release, aucun tag ni historique Git n'est supprimé ou réécrit.
- Les documents du 16 octobre restent des archives et ne définissent pas cette refonte.

## Contrat visuel

- Reprendre exactement les couleurs sémantiques, l'accent, les teintes de `FileKind`, les couleurs de dossiers et de tags et les matières de l'application de référence.
- Réutiliser les constantes `DS`, les cartes existantes, SF Symbols et la typographie système. Ne pas ajouter de palette, de police, de dégradé décoratif ou de dépendance.
- Privilégier le contenu, des alignements réguliers, des séparateurs discrets et des commandes natives. Éviter les grands espaces vides et les cartes inutilement étirées.
- Optimiser le plein écran 13 pouces paysage, sans sacrifier le portrait, les fenêtres étroites, le clavier ou les grandes tailles de texte.
- L'iPhone conserve son interface, ses préférences et son ordre d'onglets.

## Direction proposée par onglet

### Navigation principale

Sur iPad seulement, utiliser cinq onglets natifs : Accueil, Favoris, Tag, Profil et Réglages. Privilégier la barre d'onglets native, sans barre latérale globale personnalisée. Chaque onglet possède sa navigation indépendante ; ne pas réintroduire un `NavigationSplitView` autour de plusieurs piles rendues invisibles par leur opacité.

Le système doit isoler les commandes de chaque onglet. Revenir dans un onglet doit retrouver son dossier et ses données, sans recopier les chemins entre onglets. Conserver l'isolation par session, le verrouillage et les présentations de médias.

### Accueil

Une galerie de fichiers exploite la largeur disponible, avec des miniatures lisibles et des marges cohérentes. Le chemin, le compteur et les commandes sont hiérarchisés sans répéter les outils de navigation. Le bouton d'import reste accessible sans recouvrir les fichiers ou les transferts.

### Favoris

Employer la même présentation de galerie que l'Accueil, en conservant la véritable source `.favorites`. Afficher une seule commande par fonction. Distinguer les favoris réellement vides, le chargement, une erreur et une recherche sans résultat ; ne pas masquer un problème de données derrière un faux état vide.

### Tag

Sur une fenêtre large, proposer les catégories dans un panneau compact et les fichiers de la catégorie dans l'espace principal. Réutiliser les sources et opérations de tags existantes. Revenir à une navigation simple quand la largeur ou la taille de texte ne permet plus deux zones lisibles.

### Profil

Donner la priorité aux uploads récents dans la zone principale. Regrouper la corbeille, la version et les mesures réseau dans une zone secondaire compacte. Réutiliser les sections et chargements existants plutôt qu'ajouter un tableau de bord ou de nouvelles statistiques.

### Réglages

Afficher les catégories et les options côte à côte sur une fenêtre large, avec une largeur de formulaire lisible. Conserver la recherche et toutes les actions existantes. La catégorie sélectionnée doit survivre au redimensionnement et aux changements d'onglet, sans liaison de navigation artificielle qui renvoie toujours un chemin vide.

## Critères de réussite

1. Ouvrir plusieurs niveaux de dossiers, revenir en arrière et changer d'onglet dix fois sans plantage ni destination incorrecte.
2. Avec des favoris connus, retrouver leurs fichiers et dossiers ; ouvrir un dossier favori et revenir à la liste correcte.
3. Après chaque transition, n'afficher qu'un contrôle Filtre, Recherche et Sélection lorsque ces contrôles sont prévus sur l'écran actif.
4. Conserver les chemins indépendants, les filtres et les données des onglets après plusieurs allers-retours.
5. En portrait, paysage et fenêtre étroite, conserver les cinq destinations et des commandes accessibles, sans chevauchement.
6. Ne pas réécrire les préférences de densité iPhone lors du calcul de la disposition iPad.
7. Garder les progressions de transfert et leurs actions visibles, sans saut de grille ni obstruction du bouton d'import.
8. Conserver le verrouillage et l'isolation des comptes et drives, y compris quand une visionneuse ou une feuille est ouverte.
9. Vérifier clair/sombre, VoiceOver, Réduire les animations, Réduire la transparence et grandes tailles de texte. Les cibles tactiles font au moins 44 points.
10. Comparer visuellement les cinq onglets avec la palette de référence ; aucun nouveau traitement colorimétrique propre à l'iPad.

## Structure et conventions

- `Orvian/App/` : sélection d'onglet et état de navigation possédé par la session.
- `Orvian/Features/` : présentation spécifique de chaque écran ; conserver les services et modèles existants.
- `Orvian/UI/` : uniquement les éléments de présentation réellement partagés.
- `Tests/` : vérifications Swift pures et contrôles Python existants.
- `Tests/iOS/` : tests hébergés de logique et d'intégration ; ils ne remplacent pas les parcours UI sur iPad.

Respecter le style SwiftUI actuel et les jetons existants, par exemple :

```swift
Label("Favoris", systemImage: "heart")
    .foregroundStyle(.primary)
    .padding(DS.gridMargin)
```

## Vérification et commandes

Tests locaux disponibles sous Windows :

```powershell
python -B -m unittest Tests.test_audit_integration Tests.test_requested_fixes Tests.test_filter_menu Tests.test_recent_sharing Tests.test_ui_cleanup
git diff 3387c1e -- Orvian Tests .github/scripts/check_ios_regressions.py .github/workflows/build.yml
```

La seconde commande prouve le retour à la base avant reconstruction ; un diff est ensuite attendu pendant la refonte.

Vérifications sur macOS avec Xcode :

```sh
xcodegen generate
python3 .github/scripts/check_ios_regressions.py
xcrun simctl list devices available
xcodebuild -project Orvian.xcodeproj -scheme Orvian -destination "platform=iOS Simulator,id=$IPAD_SIMULATOR_UDID" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
xcodebuild -project Orvian.xcodeproj -scheme Orvian -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Définir `IPAD_SIMULATOR_UDID` avec un simulateur iPad 13 pouces disponible. Ajouter une preuve de régression pour chaque mécanisme corrigé, avant le correctif. Tester les transitions visuelles sur iPad : une assertion de largeur ou un test hébergé exécuté sur iPhone ne prouve pas leur bon fonctionnement.

Le processus d'acceptation exige les parcours rapportés sur simulateur iPad et appareil réel. Tant que ces essais manquent, ne pas présenter la refonte comme validée ou « sans bug ».

## Limites et décisions à approuver

- Toujours : repartir des sources restaurées, préserver les couleurs et l'iPhone, conserver les validations et la sécurité, vérifier chaque changement de comportement.
- Demander avant : publication, push, changement d'API ou de stockage, nouvelle dépendance et modification des destinations de test de la CI.
- Ne jamais : supprimer des données utilisateur, réécrire l'historique, supprimer une release existante, désactiver un test pour masquer un échec ou promettre l'absence totale de bugs sans preuve d'exécution.
- Hors périmètre : nouveau moteur de favoris, changement des API, du modèle NSFW ou de l'identité graphique.
- Direction approuvée : conserver l'identité visuelle et utiliser une navigation principale par onglets natifs, sans reprendre la barre latérale globale supprimée. L'utilisateur a ensuite demandé le push sur main et la surveillance de GitHub Actions.

## Sources

- Référence produit : `3387c1e`, notamment `Orvian/UI/DesignSystem.swift`, `Orvian/UI/FloatingTabBar.swift` et `Orvian/Core/Utils/FileKind.swift`.
- Apple : https://developer.apple.com/documentation/swiftui/tabview
- Apple : https://developer.apple.com/documentation/swiftui/tabviewstyle/tabbaronly
- Les recommandations du catalogue de design consulté étaient trop orientées web et proposaient d'autres palettes. Elles ne sont pas retenues ; l'application existante reste la référence visuelle.
