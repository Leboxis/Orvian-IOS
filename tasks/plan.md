# Plan : reconstruire Orvian pour iPad 13 pouces

## Cadre

La direction de `docs/superpowers/specs/2026-10-17-ipad-rebuild-design.md` et l'implémentation sont approuvées. Ce document précise les choix d'interface et l'ordre de réalisation. L'utilisateur demande désormais un push sur main après réalisation et la surveillance de GitHub Actions.

La base restaurée reste `3387c1e`. Les modifications de retrait sont conservées sur `feat/ipad-rebuild`, sans commit ni publication. Les tâches détaillées sont suivies uniquement dans `tasks/todo.md`.

## Règles communes

- Cinq onglets natifs sur iPad : Accueil, Favoris, Tag, Profil, Réglages. Utiliser `TabView` avec le style `tabBarOnly`, sans conteneur de navigation global autour des onglets et sans appeler le `tabPane` iPhone qui superpose des piles cachées.
- Garder la branche iPhone de référence. La session reste propriétaire des chemins et du routeur ; le verrouillage et les visionneuses conservent leur point de présentation commun.
- Une seule barre de commandes pour l'écran de fichiers actif. Le mode Sélection remplace les commandes normales au lieu de les compléter.
- Mesurer la largeur du contenu, pas celle de l'écran physique. Une rotation ou un redimensionnement ne change jamais l'identité de la session ou du drive.
- Reprendre `Color.accentColor`, les couleurs sémantiques système, les teintes de fichiers, les couleurs personnalisées et les matières existantes. Ne pas modifier `FileKind`, `TagPalette` ou les assets pour créer une identité iPad.
- Les cartes gardent leurs formes actuelles. Leur nombre change avec l'espace ; elles ne s'étirent pas pour remplir arbitrairement une ligne. Densité et marges iPhone restent inchangées.
- Le clavier, les grandes tailles de texte et les petites fenêtres peuvent simplifier la disposition. Deux colonnes ne sont pas une obligation lorsque leur contenu devient illisible.
- Pas de troisième colonne vide, de tableau de bord décoratif, de nouvelle statistique ou de nouveau service.

## 1. Accueil : parcourir, pas administrer

**Composition.** Une galerie large occupe le contenu. Un bandeau compact présente le chemin courant et le compteur, sans répéter le nom du dossier dans plusieurs grands titres. La recherche reste à cet endroit lorsqu'elle est demandée ou lorsque la préférence existante l'impose.

**Commandes.** Filtres, recherche, sélection et ajout sont identifiables et présents une seule fois. Sur iPad, l'ajout rejoint la barre de commandes plutôt qu'un bouton flottant concurrent des transferts. Les actions secondaires, notamment le scan du dossier et la lecture aléatoire, restent accessibles dans un menu discret. Le retour appartient à la pile de navigation, pas à un bouton personnalisé qui recopie son chemin.

**Sélection.** Afficher le nombre d'éléments sélectionnés et les actions existantes de tags, déplacement et corbeille. Conserver les confirmations, les états occupés et le fait que les actions ciblent les éléments réellement visibles.

**Fenêtre étroite.** Réduire les colonnes, laisser les actions secondaires dans le menu et conserver les cibles tactiles. Ne jamais recharger un dossier pour un simple changement de taille.

**Preuve attendue.** Ouvrir trois niveaux, revenir, changer d'onglet, redimensionner et retrouver le bon dossier avec une seule occurrence de chaque commande.

## 2. Favoris : une collection fiable, pas une deuxième navigation globale

**Composition.** Employer le même rythme et les mêmes cartes que l'Accueil. Afficher un titre compact et le compteur, sans panneau latéral supplémentaire. Conserver la source `.favorites` et ses mécanismes de cache et de pagination.

**Comportement.** Ouvrir un dossier favori dans la pile des Favoris, sans modifier l'Accueil. Après son retour, retrouver la recherche, les filtres et la position de la collection. Retirer un favori met à jour la collection sans effacer les autres fichiers.

**États.** Réutiliser les états existants de `FileGridView`, qui distinguent déjà chargement, erreur, collection vide et résultat filtré vide. Ne pas remplacer un diagnostic absent par un nouveau moteur de favoris. Si le problème persiste avec la navigation isolée, reproduire et corriger son mécanisme avant de modifier la source de données.

**Preuve attendue.** Utiliser un compte de test contenant des favoris connus ; vérifier les résultats après plusieurs allers-retours et l'absence de doublons Filtre / Recherche / Sélection.

## 3. Tag : choisir une catégorie sans perdre les fichiers de vue

**Composition large.** Un panneau de catégories d'environ 280 points utilise les couleurs et les composants actuels. Le reste affiche les fichiers du tag choisi. La gestion des tags reste dans le panneau des catégories ; les filtres de fichiers appartiennent au contenu, sans fusionner les deux ensembles de commandes.

**Identité et navigation.** Conserver un identifiant de tag sélectionné et un chemin de dossiers cohérents. Le modèle de `CategoryFilesView` est actuellement créé dans son initialiseur : changer la valeur de `category` sans changer l'identité de cette grille pourrait conserver l'ancien modèle. Recréer uniquement le détail concerné lors d'un changement de tag, jamais tout l'onglet lors d'un redimensionnement. Choisir un autre tag remet son chemin de dossiers dans un état défini, sans réutiliser le chemin du tag précédent.

**Gestion existante.** Préserver création, renommage, suppression, ordre personnalisé, réarrangement et alternatives accessibles au glisser-déposer. Le panneau de navigation iPad utilise une liste compacte native, afin de confier les transitions aux sélections documentées de `NavigationSplitView`, sans pilotage de `preferredCompactColumn`. Le choix grille/liste et les colonnes des catégories restent inchangés sur iPhone ; les réglages iPad précisent cette portée et ne réécrivent pas ces préférences pour adapter la disposition.

**Fenêtre étroite.** Afficher catégories puis fichiers dans une navigation simple. Revenir à une grande fenêtre conserve le tag actif et le dossier consulté. La suppression du tag actif doit fermer son ancien détail proprement.

**Preuve attendue.** Alterner deux tags aux fichiers différents, ouvrir leurs dossiers, changer de largeur puis supprimer un tag de test ; aucune grille ou destination du tag précédent ne subsiste.

## 4. Profil : une vue d'ensemble utile et mesurée

**Composition.** Réserver environ deux tiers de la largeur aux uploads récents, et une zone secondaire compacte à la corbeille, la version et les mesures réseau. Éviter deux listes géantes de même importance.

**Aperçu.** Sur iPad large, présenter jusqu'à six miniatures en une petite grille, depuis les fichiers déjà fournis par `RecentUploadsLoader`. Sur iPhone, garder exactement les trois miniatures actuelles. Ne pas déclencher une pagination supplémentaire pour remplir un aperçu.

**Interactions.** Chaque miniature ouvre le routeur existant. « Voir plus » ouvre la liste complète existante. Garder le tri stable des aperçus et la mise à jour après import, sans doubler les requêtes lors d'un retour dans l'onglet.

**Fenêtre étroite.** Replacer les informations sous les récents. Les placeholders suivent la même grille que les cartes pour éviter un saut au chargement.

**Preuve attendue.** Vérifier 0, 1, 3 et 6 fichiers, les noms longs, un nouvel upload et le maintien de l'aperçu iPhone à trois cartes. Adapter les tests actuels qui vérifient littéralement `prefix(3)` pour couvrir explicitement les deux présentations, sans retirer la garantie iPhone.

## 5. Réglages : un formulaire lisible, pas une mosaïque

**Composition large.** Une zone compacte à gauche contient le compte et les cinq espaces actuels. La zone principale présente les réglages de l'espace choisi dans une largeur de lecture plafonnée, autour de 700 points, plutôt que d'étirer les interrupteurs sur tout l'écran.

**Recherche.** Les résultats restent directement modifiables dans la zone principale. La liste des espaces peut rester visible sur une grande fenêtre. Ne pas dupliquer le champ de recherche ni effacer la saisie à cause d'une rotation.

**État.** Posséder une sélection typée pour l'espace iPad et conserver la vraie pile compacte ; ne pas utiliser une liaison qui renvoie artificiellement `[]` et ignore les écritures en mode large. Passer de large à étroit doit afficher le même espace, pas revenir silencieusement à Apparence.

**Sécurité et actions.** Réutiliser strictement les callbacks de code, de changement de drive, de cache et de déconnexion. Conserver les confirmations et ne jamais afficher un token en clair pour remplir l'espace.

**Preuve attendue.** Ouvrir Sécurité, rechercher un réglage, changer d'onglet et redimensionner ; contrôler que sélection, recherche et valeurs restent cohérentes.

## Transferts et présentations

Les progressions conservent une zone de superposition stable, dimensionnée pour les transferts simultanés. Leur apparition ne pousse pas la grille et n'obstrue pas les dernières cartes. Garder leurs actions Annuler et Détails. Les feuilles et visionneuses ne sont pas reconstruites lors d'un changement de largeur et restent couvertes par le verrouillage existant.

## Ordre de réalisation

1. Isoler la navigation native et vérifier d'abord les parcours cassés, avant toute mise en page en colonnes.
2. Adapter la grille commune, puis traiter Accueil et Favoris avec leurs vraies sources.
3. Valider ce socle avant d'adapter Tag et ses changements d'identité.
4. Adapter Profil puis Réglages, sans nouvelle couche de services.
5. Vérifier transferts, présentations, accessibilité et non-régression iPhone.

Les dépendances et points de contrôle sont détaillés dans `tasks/todo.md`. Aucun travail parallèle sur la navigation ou les sources partagées.

## Vérification et risques

- Chaque comportement ajouté commence par une preuve de régression adaptée : état et calculs dans les tests, affichage et gestes dans une vraie exécution iPad.
- Les assertions de largeur ne prouvent pas l'absence de boutons dupliqués. Les dix cycles entre onglets et les ouvertures de dossiers doivent être exécutés sur iPad.
- Le réappui sur un onglet natif doit être observé sur iPadOS 26 ; ne pas prétendre le détecter avec un simple `onChange` lorsque la sélection ne change pas. Le comportement iPhone existant ne change pas.
- Après la demande de publication et de surveillance, la CI conserve les vérifications iPhone et ajoute une étape iPad distincte, bloquante pour la génération de l'IPA. Le résultat XCTest iPad est joint en artefact. Un workflow de contrôle sera lancé sur la branche de refonte avant le push sur main.
- Sous Windows, ni Xcode ni le rendu SwiftUI ne sont disponibles. Sans essais sur simulateur iPad et appareil, le statut reste « implémenté, validation iPad en attente », jamais « sans bug ».

Commandes existantes à conserver :

```powershell
python -B -m unittest Tests.test_audit_integration Tests.test_requested_fixes Tests.test_filter_menu Tests.test_recent_sharing Tests.test_ui_cleanup
```

```sh
xcodegen generate
python3 .github/scripts/check_ios_regressions.py
xcodebuild -project Orvian.xcodeproj -scheme Orvian -destination "platform=iOS Simulator,id=$IPAD_SIMULATOR_UDID" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
xcodebuild -project Orvian.xcodeproj -scheme Orvian -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Définir `IPAD_SIMULATOR_UDID` avec le simulateur 13 pouces disponible. L'exécution des tests du schéma ne remplace pas les parcours visuels et les gestes réels.

## Références techniques

Projet vérifié : Swift 5, SwiftUI, iOS/iPadOS 26 minimum, XcodeGen (`project.yml`). Les API suivantes sont documentées pour cette cible :

- Onglets natifs : https://developer.apple.com/documentation/swiftui/tabview
- Style sans barre latérale globale : https://developer.apple.com/documentation/swiftui/tabviewstyle/tabbaronly
- Colonnes internes pour les écrans qui le nécessitent, pas pour regrouper les cinq onglets : https://developer.apple.com/documentation/swiftui/navigationsplitview
- Mesure ciblée de géométrie, sans reconstruire tout l'arbre à chaque défilement : https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)
- Changement de composition sans destruction de l'état : https://developer.apple.com/documentation/swiftui/anylayout
- Sélections natives dans les colonnes : https://developer.apple.com/documentation/swiftui/migrating-to-new-navigation-types

Les largeurs et proportions décrites sont des cibles de composition à valider avec du contenu réel et de grandes tailles de texte, pas une promesse de rendu déjà testé.
