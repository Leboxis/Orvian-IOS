# Tâches : refonte iPad depuis la base restaurée

Plan : `tasks/plan.md`. Statut : code des tâches 1 à 8 implémenté ; vérifications locales réussies, validation Xcode et iPad en attente du contrôle CI. Les coches d'implémentation ne signifient pas que les essais manuels ont été réalisés. Les points de contrôle de validation restent distincts.

## 1. Navigation native isolée

- [x] Remplacer uniquement sur iPad la navigation superposée par des onglets natifs.
- Acceptation : une pile indépendante par onglet ; présentations communes toujours protégées par le verrouillage ; branche iPhone inchangée.
- Vérification : tests hébergés de l'état et du conteneur, puis dix cycles entre onglets et ouvertures de dossiers sur iPad, avec contrôle des commandes visibles.
- Dépendances : aucune.
- Fichiers probables : `Orvian/App/MainTabView.swift`, `Orvian/App/IPadTabView.swift`, `Tests/iOS/IPadNavigationTests.swift`.
- Taille : moyenne.

### Point de contrôle : navigation

- [ ] Le parcours rapporté ne reproduit plus le défaut sur iPad ; si aucun runtime iPad n'est disponible, conserver explicitement ce blocage avant de déclarer le socle validé.

## 2. Grille adaptée à la largeur réelle

- [x] Adapter la présentation des fichiers sans modifier les sources ni les préférences iPhone.
- Acceptation : cartes lisibles sur grande et petite fenêtre ; redimensionnement sans changement de session ni retour à la racine ; styles actuels conservés.
- Vérification : tests des largeurs initiales, étroites et 13 pouces, des préférences limites et du repli avec grande taille de texte ; inspection en portrait/paysage.
- Dépendances : 1.
- Fichiers probables : `Orvian/UI/IPadLayout.swift`, `Orvian/UI/DesignSystem.swift`, `Orvian/App/IPadTabView.swift`, `Orvian/Features/Shared/FileGridView.swift`, `Tests/iOS/IPadLayoutTests.swift`.
- Taille : moyenne.

## 3. Accueil lisible et commandes uniques

- [x] Composer le bandeau de dossier et les commandes iPad sans modifier la navigation ou les mutations métier.
- Acceptation : ajout accessible sans bouton flottant concurrent ; recherche et sélection présentes une fois ; scan, aléatoire et confirmations toujours accessibles.
- Vérification : ouvrir trois niveaux, rechercher, filtrer et sélectionner ; contrôler les mutations sur des fichiers de test et les commandes après retour arrière.
- Dépendances : 1, 2.
- Fichiers probables : `Orvian/Features/Home/DirectoryView.swift`, `Orvian/Features/Home/HomeTab.swift`, `Tests/iOS/IPadBrowserTests.swift`.
- Taille : moyenne.

## 4. Favoris fiables

- [x] Adapter la collection des Favoris au même langage de présentation que l'Accueil.
- Acceptation : source `.favorites` conservée ; dossier ouvert dans la bonne pile ; chargement, erreur et résultats vides non confondus.
- Vérification : compte de test avec favoris connus, retour après changement d'onglet, retrait d'un favori et comptage des commandes visibles ; tests Python existants.
- Dépendances : 1, 2, 3.
- Fichiers probables : `Orvian/Features/Favorites/FavoritesView.swift`, `Tests/iOS/IPadBrowserTests.swift`.
- Taille : petite. Si un défaut de données reste reproductible, ajouter une tâche ciblée avant de modifier un service.

### Point de contrôle : navigation et fichiers

- [ ] Tests exécutables disponibles réussis, compilation iOS et parcours Accueil/Favoris vérifiés sur iPad ; revue humaine du résultat avant les écrans en deux zones.

## 5. Tags et identité du détail

- [x] Présenter catégories et fichiers côte à côte sur grande fenêtre en réutilisant le chargement existant.
- Acceptation : chaque tag affiche son propre modèle ; chemin de dossiers cohérent au changement de catégorie et de largeur ; gestion et ordre des tags préservés.
- Vérification : deux catégories aux fichiers distincts, ouverture de sous-dossiers, suppression du tag actif et repli étroit, avec tests d'état dédiés.
- Dépendances : 1, 2, 4.
- Fichiers probables : `Orvian/Features/Tag/TagsView.swift`, `Orvian/App/TabNavigationState.swift`, `Tests/iOS/IPadTagsTests.swift`.
- Taille : moyenne. Extraire seulement un composant réellement nécessaire si le fichier grossit excessivement.

## 6. Profil hiérarchisé

- [x] Donner la priorité aux récents avec un aperçu iPad de six cartes maximum et des informations secondaires compactes.
- Acceptation : iPhone toujours limité à trois cartes ; même loader et même tri stable ; aucune pagination supplémentaire pour remplir l'aperçu.
- Vérification : 0, 1, 3 et 6 fichiers, import récent et retour dans l'onglet ; adapter les assertions Python pour couvrir les deux présentations sans supprimer la garantie iPhone.
- Dépendances : 1, 2.
- Fichiers probables : `Orvian/Features/Profile/ProfileView.swift`, `Tests/test_recent_sharing.py`, `Tests/iOS/IPadProfileTests.swift`.
- Taille : moyenne.

## 7. Réglages et sélection persistante

- [x] Présenter espaces et formulaires côte à côte sans fausse liaison de navigation compacte.
- Acceptation : même espace après redimensionnement et changement d'onglet ; recherche directement utilisable ; callbacks de sécurité, cache et compte inchangés.
- Vérification : tester la sélection typée, puis Sécurité et Compte en large/étroit, avec recherche et feuilles ouvertes ; tests Python existants.
- Dépendances : 1, 2, 5.
- Fichiers probables : `Orvian/Features/Settings/SettingsView.swift`, `Orvian/App/TabNavigationState.swift`, `Tests/iOS/IPadSettingsTests.swift`.
- Taille : moyenne. Si une extraction des espaces devient nécessaire, la vérifier séparément avant d'ajouter le nouveau comportement.

### Point de contrôle : cinq onglets

- [ ] Revue des cinq onglets sur iPad 13 pouces, petites fenêtres, clair/sombre et grands textes ; comparaison de la palette et de l'iPhone de référence.

## 8. Transferts, présentations et accessibilité

- [x] Finaliser les réserves de contenu et les comportements qui traversent les onglets.
- Acceptation : aucun saut de grille lors des transferts ; actions et dernières cartes accessibles ; verrouillage, feuilles et visionneuses cohérents.
- Vérification : envoi et téléchargement simultanés, rotation avec une feuille ouverte, verrouillage avec visionneuse, VoiceOver et réglages de réduction des animations/transparences.
- Dépendances : 3, 4, 5, 6, 7.
- Fichiers probables : `Orvian/App/MainTabView.swift`, `Orvian/App/IPadTabView.swift`, `Tests/iOS/IPadBrowserTests.swift`, `Tests/IOSRegressionChecklist.md`.
- Taille : moyenne.

## 9. Preuves finales et décision de livraison

- [ ] Exécuter et consigner les vérifications du plan ; ne pas confondre tests hébergés, compilation et validation des gestes.
- Acceptation : aucune régression connue laissée silencieusement ouverte ; chaque vérification manquante est indiquée ; aucun push ou release sans demande.
- Vérification : commandes de `tasks/plan.md`, parcours des dix cycles et favoris connus sur iPad réel, puis comparaison iPhone.
- Dépendances : 1 à 8.
- Fichiers probables : `Tests/IOSRegressionChecklist.md`, `tasks/todo.md`.
- Taille : petite. La demande de publication surveillée inclut maintenant une étape CI iPad distincte et un contrôle préalable sur la branche de refonte.

### Point de contrôle : terminé

- [ ] Tous les critères de la spécification sont étayés par une preuve ou un blocage clairement signalé. Aucun statut « sans bug » ne repose uniquement sur une compilation ou des tests Python.

## Exécution et limites

- 35 tests Python hors outillage ML passent. Les contrôles de mouvement et d'isolation passent également.
- Quatre contrôles structurels ont échoué avant l'ajout du conteneur natif, puis sont passés. Une inversion temporaire de la garde de sélection a été détectée ; le code correct est restauré.
- Dix tests iOS couvrent la disposition, les sélections de tags et réglages, dix cycles du conteneur natif et le rendu des véritables écrans et destinations de dossiers dans les deux thèmes sans credentials. Les captures sont jointes au résultat XCTest ; ces essais sans compte ne prouvent pas le chargement des favoris d'un compte réel.
- Les couleurs et constantes existantes restent inchangées ; les nouveaux fonds utilisent uniquement les couleurs système déjà présentes dans l'application.
- Aucun changement d'API, d'authentification, de cache ou de modèle NSFW. Aucun test existant désactivé pour masquer un défaut.
- Sous Windows, aucun build SwiftUI ni test XCTest n'a pu être lancé localement. Le push sur main attend le résultat du workflow de contrôle ; les essais avec un compte et sur appareil réel restent ouverts.
