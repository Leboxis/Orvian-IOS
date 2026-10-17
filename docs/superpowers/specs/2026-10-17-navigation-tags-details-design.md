# Navigation, affichages et nouvelle fiche Détails

Statut : validé par l'utilisateur, exécution directe puis push autorisés.
Les réponses utilisateur dans cette conversation sont la référence.
Complément : aucune validation visuelle ni capture via GitHub Actions.

## Intention et contraintes

Restaurer les commandes demandées sans nouvelle réorganisation arbitraire,
corriger les actions grisées des Favoris, ajouter le croisement de tags et les
listes iPad, remplacer entièrement la présentation de Détails.

Conserver SwiftUI/UIKit, iOS 26 et les services/cache/transferts existants.
Aucune nouvelle dépendance. Conserver confirmations destructives, isolation
par compte/drive, erreurs réseau, pagination et accessibilité.

Travail en trois lots : commandes/navigation et bugs ; listes et croisement ;
fiche Détails. Ce document décrit le comportement de chacun, pas un nouveau
design système pour toute l'app.

## 1. Navigation et boutons : choix protégés

Sur iPhone et iPad, y compris la barre native et la barre basse optionnelle,
l'ordre de gauche à droite est :

**Réglages — Tags — Accueil — Favoris — Profil**.

Le nom visible Activité devient Profil ; les clés de navigation persistées
n'ont pas à changer. Même ordre dans le menu de navigation pour grand texte.

Dans Accueil, Favoris et le contenu d'un tag ouvert, y compris les résultats
croisés, afficher deux boutons séparés en haut à droite : **Hasard à gauche,
Sélectionner à droite**. Ils remplacent le menu qui réunissait ces commandes.
Hasard ouvre un fichier non dossier parmi les éléments actuellement affichés,
selon recherche, tri et filtres. Sélectionner permet les opérations de sélection
déjà disponibles dans les navigateurs ; la vue d'un tag doit proposer le même
mode de sélection et ses actions applicables.

Ces deux commandes restent ensemble et dans cet ordre ; les autres commandes
(Ajouter, présentation, filtres) ne doivent pas s'intercaler entre elles.
Les icônes peuvent rester compactes ; zones tactiles >= 44 pt et noms accessibles.

Diagnostic à faire avant modification des Favoris : reproduire la désynchronisation
entre le rapport d'éléments visibles et sa version de données/filtrage. Ne pas
simplement forcer les boutons à être actifs. Avec une liste de fichiers chargés,
les deux commandes doivent être utilisables ; dans un dossier ne contenant que
des dossiers, Sélectionner reste disponible mais Hasard est désactivé. Aucun
résultat affiché signifie aucune sélection ni ouverture aléatoire possible.

Inscrire cet ordre et la disposition des boutons dans les instructions du dépôt
avec tests de non-régression. Toute modification volontaire de ces choix exigera
une autorisation explicite de l'utilisateur. La protection ne s'étend pas aux
autres choix visuels de cette spécification.

## 2. Densité iPhone

L'utilisateur a annulé quatre colonnes : **trois maximum**. Réglage à deux ou
trois colonnes seulement sur iPhone ; les grandes tailles de texte et les fenêtres
étroites peuvent réduire le nombre effectif. Ne pas proposer des niveaux sans
effet au-dessus de trois sur iPhone. Normaliser la présentation d'une ancienne
préférence supérieure à trois sans dégrader les réglages de densité iPad.

Choix technique proposé : préférences effectives distinctes par plateforme,
avec reprise de l'ancienne valeur plafonnée pour l'iPhone. L'iPad conserve ses
six niveaux de densité. Les détails de migration relèvent de l'implémentation.

## 3. Liste / grille sur iPad

Ajouter un bouton de présentation dans Accueil, Favoris et les fichiers des Tags.
Chaque onglet conserve son choix liste/grille entre visites et après relancement ;
le choix Tags s'applique aussi aux résultats croisés et aux dossiers parcourus
depuis cet onglet. L'iPhone conserve sa grille de fichiers, sauf instruction future.

Liste détaillée iPad : miniature compacte, nom, type, taille, dernière modification
et tags disponibles. Adapter les colonnes à la largeur réelle : masquer d'abord
les informations secondaires, jamais le nom ou les commandes essentielles.
Les dossiers n'affichent pas un poids fictif. Ne pas lancer des requêtes
individuelles pour remplir toutes les lignes. Les vues liste et grille partagent
strictement les mêmes éléments, filtres, sélection, menus, pagination et visionneuses.

Le catalogue de tags dispose également d'un bouton liste/grille sur iPad.
Sur iPhone, conserver celui qui existe. La présentation du catalogue est distincte
de celle des fichiers : deux réglages séparés pour éviter les changements implicites.
Le positionnement précis du catalogue dans la navigation iPad à colonnes est laissé
à l'implémentation, sans déplacer les onglets ni les commandes protégées.

## 4. Croisement de tags : intersection, jamais union

Ajouter un bouton d'entrée en mode sélection multiple de tags :
- iPad : immédiatement à gauche du bouton existant Ajouter / Réarranger.
- iPhone : immédiatement à gauche du bouton existant Liste / Grille.

En mode croisé, toucher un tag le coche/décoche ; ce toucher ne doit pas ouvrir
le tag comme en navigation normale. Les résultats se mettent à jour à chaque
changement, sans bouton Appliquer. Un court regroupement des frappes réseau est
autorisé ; la sélection visuelle répond immédiatement et les anciens chargements
ne doivent jamais remplacer les résultats d'une sélection plus récente.

Un élément apparaît uniquement s'il porte lui-même **tous** les tags sélectionnés.
Inclure fichiers et dossiers. Les enfants d'un dossier tagué n'héritent pas de ses
tags. Zéro sélection : inviter à choisir des tags, sans charger tout le drive.
Un seul tag : mêmes résultats que son ouverture habituelle.

Sur iPad large, conserver les choix de tags et les résultats visibles dans les
colonnes existantes ; sur iPhone et fenêtre compacte, prévoir une présentation
permettant de consulter les résultats et de revenir modifier les coches sans
perdre la sélection. Le détail précis des transitions relève de l'implémentation.

**Terminer conserve les résultats** et masque les coches. Afficher les noms des
tags actifs et une commande pour modifier ou effacer le croisement. Effacer revient
au catalogue normal. Choix proposé : conserver cet état pendant les changements
d'onglet, mais ne pas restaurer un croisement au prochain lancement. Changer de
compte/drive le réinitialise. En cas de suppression d'un tag actif, ne pas élargir
silencieusement les résultats : signaler ce changement et demander d'ajuster le filtre.

Les résultats sont paginés : une première page sans correspondance ne signifie
pas qu'aucun résultat n'existe. Continuer vers les pages suivantes en affichant un
chargement explicite ; proposer Réessayer lors d'un échec. N'annoncer un résultat
vide définitif qu'après épuisement des pages. Un compteur partiel est nommé comme
tel. Aucun résultat périmé ne sert à sélectionner ou ouvrir un fichier au hasard.

Choix technique proposé, à confirmer contre l'API : réutiliser une recherche par
tag paginée et vérifier les autres appartenances sur chaque résultat. Ne pas
supposer qu'un paramètre multi-tags serveur signifie AND sans vérification.
Compléter une appartenance absente uniquement si nécessaire, avec concurrence
bornée et annulation. Une erreur de métadonnées n'est pas une non-correspondance.
Les clés de cache et mutations doivent inclure la combinaison normalisée des tags
et l'identité compte/drive ; réévaluer les résultats après modification des tags.

## 5. Détails : refonte complète, lecture seule

### Présentation

- iPhone : feuille défilante, fermeture explicite.
- iPad en largeur suffisante : panneau inspecteur à droite, navigateur visible
  et utilisable ; remplacer son contenu lorsqu'un autre Détails est demandé.
- iPad compact : repli en feuille si un panneau rend le navigateur inutilisable.
  Ce seuil adaptatif est un choix d'implémentation.

**Aucun bouton Ouvrir, Télécharger, Favori, Tags, Renommer, Déplacer ou Supprimer,
et aucun menu d'opérations dans Détails.** Les opérations restent dans les menus
contextuels des éléments. Seuls Fermer et les éventuelles reprises de chargement
sont des commandes. Le texte peut être sélectionné pour copie avec le système.
L'emplacement est informatif : pas de nouvelle action de navigation dans la fiche.

### Structure visuelle

Style sobre et natif : couleurs sémantiques, SF Symbols, arrondis et marges de
l'app ; pas de grande image, de dégradé décoratif ni de grandes cartes vides.

1. **Identité compacte** : petite miniature à côté du nom complet, type/format et
   taille ; indicateur de favori non interactif et état corbeille le cas échéant.
2. **Repères immédiats** : dates d'ajout et modification, caractéristiques média
   disponibles (dimensions, résolution, durée). Regroupement compact et lisible,
   sans répéter inutilement type/poids ailleurs.
3. **Organisation** : tags nommés avec couleurs ; dossier parent et chemin complet
   disponibles, retours à la ligne plutôt que masquage permanent des valeurs.

Le nom et les libellés ne sont pas tronqués en grand texte. Les valeurs essentielles
restent hautes dans la fiche ; pas de sections techniques secondaires ouvertes
par défaut. La hiérarchie doit permettre la lecture en un coup d'œil.

Charger d'abord les valeurs connues et compléter celles que le service expose.
Ne jamais inventer des métadonnées ni extraire une vidéo entière pour afficher
sa durée. Exploiter les caches existants. Les indisponibilités doivent être
distinguées d'un état vide réel, mais ne pas afficher une série de lignes « — ».
Séparer les erreurs par section pour ne pas masquer le reste de la fiche.
Respecter les endpoints de corbeille et éviter les requêtes de fichiers actifs
sur un fichier supprimé. Réagir correctement aux changements de compte, fichier,
renommage ou suppression pendant une consultation.

## 6. Validation et limites

Ajouter des tests pour les commandes Favoris avec données déjà en cache et
chargement ultérieur, changement de filtre/tri, pagination et réponse tardive.
Tester la même population visible en liste/grille, y compris pour Hasard et
Sélectionner. Tester l'intersection (0/1/plusieurs tags, dossiers, tags absents,
pagination vide intermédiaire, annulation, erreurs et séparation des comptes).
Tester les préférences, leur restauration et l'ordre des commandes protégées.

Vérifier Détails en clair/sombre, nom/chemin longs, métadonnées manquantes, erreur,
corbeille, VoiceOver, grand texte et fermeture. Captures iPhone et iPad 12,9 pouces
portrait/paysage et fenêtres compactes en CI macOS ou appareil.

L'environnement Windows permet les tests Swift de logique et les contrôles de
sources, pas la compilation SDK SwiftUI/UIKit ni la validation visuelle iOS.
Ne pas présenter un contrôle syntaxique comme un build iOS réussi.

Hors périmètre : nouveaux onglets, changement d'identité graphique globale,
nouveaux partages cloud ou statistiques fictives, modifications d'API non vérifiées,
push automatique sur main. La publication fera l'objet d'une demande explicite.
