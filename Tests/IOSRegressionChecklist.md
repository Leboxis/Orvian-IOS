# Vérification iOS des corrections d'audit

Les tests automatisés s'exécutent sur le runner macOS, en mode Swift 5 :

```sh
python3 .github/scripts/check_ios_regressions.py
python3 .github/scripts/check_favorites_cache.py
```

Le build Xcode complet suit ces contrôles dans le workflow existant. Ces tests
utilisent des secrets factices et des transferts simulés, sans compte kDrive.

## Refonte iPad du 17 octobre 2026

### Navigation et Détails — choix validés

- Pas de validation visuelle ni de captures via GitHub Actions : le test de
  captures historique est explicitement exclu des commandes CI iPhone/iPad.
  Les contrôles natifs non visuels restent actifs.
- Vérifier manuellement : Réglages — Tags — Accueil — Favoris — Profil ;
  Hasard puis Sélectionner séparés en haut à droite, y compris dans un tag ouvert.
- Favoris déjà en cache, chargement tardif, changement de filtre et pagination :
  les boutons suivent immédiatement les éléments réellement visibles.
- iPhone : deux ou trois colonnes, anciennes préférences 4–7 plafonnées sans
  modifier la densité iPad. Liste/grille iPad mémorisée par onglet et non par dossier.
- Croisement : cocher deux tags, vérifier AND (fichiers et dossiers), puis
  Terminer, Modifier, Effacer. Supprimer un tag actif ne doit pas élargir le filtre.
- Détails : inspecteur à droite en iPad régulier, feuille en compact/iPhone,
  aucune opération d'édition, chargements partiels et reprises distincts ;
  fermeture, remplacement du fichier, verrouillage et compte différent.
- Dimensions photo : uniquement celles lues dans le fichier original lors de
  sa consultation, jamais déduites de la miniature et aucun téléchargement de
  photo supplémentaire pour remplir une ligne de Détails.

### Corrections de l'audit iPhone / iPad

- iPhone 320/375/430 pt et iPad 1024×1366 / 1366×1024 : vérifier les six niveaux
  de densité, puis une fenêtre étroite. Les préférences restent enregistrées ;
  une carte n'est jamais comprimée sous 100 pt (220 pt en texte accessible,
  sauf panneau plus étroit affichant une seule colonne).
- VoiceOver : activer une carte, appeler Renommer dans ses actions, sélectionner
  un fichier et entendre son état et ses tags. Contrôler aussi le clavier complet.
- Au texte maximum, ouvrir le menu Navigation en bas : les cinq onglets gardent
  leurs noms. Vérifier champ de recherche, portée et noms de fichiers longs.
- Lancer envoi et téléchargement simultanément : la dernière ligne et les
  commandes restent accessibles, sans collision avec Ajouter (désormais en haut).
- Clavier : Command-F ouvre la recherche, Échap quitte la sélection/recherche,
  Command-A sélectionne uniquement les fichiers affichés et laisse la sélection
  du texte native quand le champ est actif. Un onglet masqué ne reçoit rien.
- Déposer depuis Fichiers 1 puis 20 documents ; contrôler nom, destination,
  progression, échec de copie et réessai. Refuser dossiers et liens. Changer
  de drive, déconnecter ou verrouiller pendant la préparation : aucun import
  tardif dans une autre session. Les fichiers sources ne sont jamais supprimés.
- Mode avion sans cache : Activité affiche une erreur et Réessayer, pas un état
  vide. Avec cache, les fichiers restent présents malgré l'erreur d'actualisation.
- Remonter directement à chaque parent depuis le menu du chemin, dans Accueil,
  Favoris et Tags, puis tester retour et changement d'onglet.
- Visionneuses image/vidéo : titre long, copie accessible, commandes de 44 pt,
  portrait/paysage, texte maximum, photos blanches et noires. Échap ferme ;
  Espace contrôle la lecture vidéo.
- Aide de connexion : défilement avec texte maximal et clavier, fermeture et
  passage de la feuille moyenne à grande. Réduire la transparence sur les cartes.

La CI exécute les tests de navigation, de disposition et d'état non visuels sur
un simulateur iPad, en plus des contrôles iPhone. Aucun résultat visuel n'est
attendu de ces jobs ; ils ne remplacent pas les essais manuels sur appareil.

À vérifier avec un compte de test et sur appareil :

- Ouvrir trois niveaux de dossiers dans Accueil et Favoris, changer d'onglet
  dix fois et revenir : aucun plantage, chemin perdu ou contrôle dupliqué.
- Contrôler des favoris connus, leur pagination, un retrait des favoris et les
  états distincts d'erreur, de collection vide et de recherche sans résultat.
- Dans Tag, changer de catégorie depuis un sous-dossier : aucun ancien fichier
  conservé dans le nouveau détail. Supprimer le tag actif puis recréer un tag.
- Redimensionner pendant la consultation de Sécurité ou d'un dossier de tag ;
  vérifier le retour natif aux catégories en fenêtre compacte.
- Vérifier le Profil avec 0, 1, 3 et 6 uploads ; l'iPhone conserve trois cartes.
- Envoyer et télécharger simultanément, vérifier les actions et la dernière
  rangée ; les progressions ne doivent pas déplacer la grille.
- Contrôler les cinq onglets en clair/sombre, portrait/paysage, grand texte,
  VoiceOver, réduction des animations et de la transparence.
- Ouvrir une visionneuse puis verrouiller l'app : aucune présentation au-dessus
  du verrou. Comparer l'iPhone à la disposition de référence.

## Parcours à vérifier sur iPhone / simulateur

- Téléchargement lent avec PIN : passer en arrière-plan puis revenir sans
  s'authentifier. Si le téléchargement termine, aucun aperçu ni partage ne
  doit apparaître au-dessus du verrou. Après déverrouillage, le partage s'ouvre
  depuis la fenêtre de contenu. Répéter avec Face ID (succès en phase inactive).
- Déconnexion pendant un téléchargement, puis reconnexion : aucun nom,
  progression ou partage de l'ancienne session ne doit réapparaître. Répéter
  avec un fichier terminé et en attente derrière le verrou.
- Sans PIN, vérifier le masque lors du passage actif → inactif → arrière-plan
  et l'aperçu du sélecteur d'applications. Avec PIN, vérifier aussi qu'un succès
  Face ID ne laisse pas d'écran noir avant la réactivation.
- Accueil : modifier le dossier depuis kDrive Web, attendre plus de 60 s, puis
  revenir sur l'onglet ou au premier plan. La liste doit se revalider. Un
  pull-to-refresh doit récupérer les modifications sans attendre 60 s.
- Ouvrir des textes UTF-16 LE et BE avec BOM (accents et emoji), UTF-8 et
  Windows-1252. Ils doivent rester lisibles ; un ZIP ou un texte contenant un
  caractère nul doit rester refusé comme contenu binaire.

- Verrouillage par code : en portrait puis en paysage, toutes les touches
  restent visibles et utilisables. Répéter avec Dynamic Type au maximum ; si
  le contenu dépasse, il doit défiler sans réduire les cibles tactiles.
- Profil : ouvrir l'onglet pendant son préchargement puis retoucher Profil.
  La seconde action doit lancer une nouvelle lecture serveur forcée et son
  résultat doit rester affiché même si la première requête termine plus tard.
- Import : simuler une confirmation perdue après réception du fichier. Aucun
  second envoi automatique ni bouton Réessayer ; le message demande de vérifier
  le dossier kDrive. Vérifier aussi la clôture d'un fichier de plus de 95 Mio.
  Un refus 429 peut être retenté, avec au maximum trois tentatives automatiques.
- Déplacer un favori portant un tag : il reste dans Favoris, dans le tag et
  dans les récents. Il quitte uniquement son ancien dossier. Ouvrir le dossier
  de destination avant puis après le déplacement : le fichier doit apparaître.
  Répéter depuis une recherche limitée à un dossier et avec un échec partiel.
- Avec un réseau ralenti, appuyer plusieurs fois sur le même tag : un seul
  changement est envoyé à la fois. Les autres tags restent utilisables. La
  fermeture attend les changements en cours ; un échec rétablit la coche.

- Installation existante : le PIN continue à déverrouiller ; sa première
  vérification réussie remplace l'ancienne empreinte par PBKDF2 salé.
- Keychain indisponible (LiveContainer) : le jeton n'est jamais réécrit dans
  UserDefaults. La connexion fonctionne pendant la session ; les réglages
  indiquent qu'une reconnexion sera nécessaire. Le PIN dérivé reste utilisable
  après redémarrage même sans Keychain.
- Cinq PIN incorrects : délai de 30 secondes affiché, touches désactivées.
  Relancer l'app conserve le délai. Une nouvelle erreur après le délai le
  double, jusqu'à une heure. Un bon PIN ou Face ID remet le compteur à zéro.
  Vérifier aussi le changement et la désactivation du PIN dans Réglages.
- Deux drives / comptes avec le même numéro de fichier : les métadonnées et
  filtres restent propres à chaque vidéo, y compris après une réponse tardive.
- Annuler un téléchargement immédiatement puis en cours de transfert : un
  nouveau téléchargement reste possible, aucune feuille de partage ne s'ouvre
  pour le fichier annulé. Annuler un envoi ne laisse pas une attente suspendue.
- Document texte de 5 Mio : ouverture et recherche de liens, défilement et
  édition. Document trop grand : erreur compréhensible, y compris sans taille
  annoncée par le serveur. Mesurer la réactivité sur l'iPhone le moins puissant.
- Mode avion avec tags non chargés : message d'échec et bouton Réessayer dans
  la fiche et l'éditeur ; aucun état vide trompeur ni modification à l'aveugle.
  Après reconnexion, les tags et leurs coches apparaissent correctement.
- Lot d'envois avec un échec : pourcentage tenant compte seulement des progrès
  réussis, puis « Erreur de transfert » à la fin.
- Panneau de filtres (menu natif) : chaque tap sur le bouton ouvre le menu ;
  un tap en dehors le referme. Choisir un tri, une orientation, « 4K+ » ou un
  mode d'affichage applique le filtre ; « Réinitialiser » réapparaît dès qu'un
  filtre est actif.
- Vérifier les nouveaux messages en mode clair/sombre et avec une grande
  taille de texte, sans débordement ni commande inaccessible.

## Lecture vidéo : gestes, pause et récupération réseau

Les transitions d'intention et l'invalidation des callbacks sont exercées par
`VideoPlaybackChecks.swift`, via `check_ios_regressions.py` sur le runner macOS.
Les scénarios suivants nécessitent aussi un iPhone ou un simulateur :

- Pendant la lecture, déplacer la barre puis interrompre le geste par une
  interruption système. Au retour, le curseur doit suivre la lecture. Répéter
  avec une vidéo en pause : elle doit rester en pause. Le geste suivant fonctionne.
- Avec un réseau ralenti, déplacer la barre puis appuyer sur Pause pendant
  la recherche. La lecture ne reprend pas à son achèvement. Répéter en ouvrant
  les tags, puis en débranchant le casque : aucun son ne repart derrière la
  feuille ni sur le haut-parleur. Fermer les tags restaure l'intention antérieure.
- Après la fin, appuyer sur Lecture puis saisir aussitôt la barre. Le retour
  à zéro annulé ne doit pas relancer le son pendant le geste. Répéter plusieurs
  déplacements rapides, en lecture puis en pause.
- Après plusieurs minutes, provoquer un échec réseau récupérable. La vidéo
  retrouve sa position et son état lecture/pause ; répéter pendant une recherche.
- Épuiser les tentatives avec une ressource indisponible : fermer l'alerte,
  vérifier que Réessayer est visible, rétablir le réseau et relancer.
- Changer de page ou fermer pendant une récupération : aucune ancienne
  recherche ne doit redémarrer la vidéo quittée.

## Limite de validation locale

Les changements ont été préparés sous Windows : la vérification syntaxique
ne remplace pas la compilation Xcode, les tests Swift et les essais ci-dessus.

## Navigation, recherche et publications réseau

Les contrôles ajoutés à `check_ios_regressions.py` compilent le code Swift de
production : publications de `Perf` (dont un reset entre capture et affichage),
recherche Unicode et annulation, préparation/nettoyage des morceaux d'upload.
La planification de recherche est aussi exercée avec les méthodes réelles de
la vue dans un état de test sans UIKit ; les événements SwiftUI restent à
vérifier sur appareil. Ces tests sont préparés pour la CI et ne sont pas
considérés comme exécutés sur Windows.

- Texte : saisir puis effacer avant 200 ms ; fermer la recherche pendant un
  balayage ; changer rapidement de mot ; modifier le document. Aucun ancien
  surlignage ne revient. Répéter en lecture et en édition, puis ouvrir un lien
  Safari et revenir. La recherche active doit fonctionner au retour.
- Diagnostic réseau : remettre les compteurs à zéro pendant une rafale ; les
  anciennes requêtes ne réapparaissent pas. Les nouvelles restent comptées.
- Code configuré : ouvrir un dossier depuis chaque onglet, puis une image,
  une vidéo ou un texte. Passer en arrière-plan et déverrouiller : même onglet
  et pile, aucune visionneuse rouverte. Déconnexion ou changement de drive :
  aucun ancien chemin restauré. Le scroll n'est pas garanti après verrouillage.
- Galerie : retirer tous les médias de la source pendant qu'elle est ouverte.
  L'état « Aucun média » et Fermer restent disponibles. Avec un filtre 4K ou
  orientation et des métadonnées non résolues : attente puis médias ou état
  vide, y compris lorsque toutes les pages réseau sont déjà chargées.
  Une résolution en échec doit proposer Réessayer, pas affirmer que la sélection
  est vide. Couper puis rétablir le réseau pour vérifier la récupération.
- Upload : fichier de plus de 95 Mio, annulation pendant la préparation et
  pendant le transfert, manque d'espace disque, puis nouvel essai. Vérifier
  aussi que l'annulation d'un envoi n'interrompt pas les autres.
- Pastilles : sans transfert, vérifier la disposition ; pendant un transfert,
  atteindre la dernière rangée et le bouton « + ». Répéter en mode clair/sombre,
  avec texte agrandi et sur une galerie de plusieurs centaines de médias.

La session d'upload partagée permet la réutilisation des connexions. Aucun
nombre de négociations TLS évitées ni gain de durée n'est garanti sans mesure.

## Suite de l’audit — septembre 2026

- Points 20 (cadence GIF) et 21 (optimisations/nettoyage de grille) exclus à la demande de l’utilisateur.
- Retour après verrouillage : ouvrir un dossier, défiler, ouvrir une photo ou
  un document, puis quitter l’app. La fenêtre de code doit masquer aussi les
  feuilles et visionneuses, le sélecteur d’apps et VoiceOver. Après le code,
  retrouver la présentation et la position ; aucune vidéo ne redémarre sous le verrou.
  Avec Face ID (succès scène encore inactive) : le tout premier tap sur le
  contenu déjà visible doit répondre immédiatement, sans tap préalable avalé.
- PIN : portrait/paysage, clair/sombre, Dynamic Type accessibilité, erreur et
  délai après essais incorrects. Le zéro et Effacer restent accessibles en
  défilant, dans le verrouillage comme dans la configuration.
- Vidéo : VoiceOver conserve les contrôles ; la progression annonce la durée
  et s’ajuste par dix secondes. Passer à la vidéo suivante conserve le muet.
  Sans VoiceOver, masquer/afficher conserve une progression exacte et AirPlay.
- Fenêtre iPad étroite : le titre reste dans la largeur de la fenêtre.
- Ancienne installation : choix de préchargement conservé. Préférence absente :
  préchargement limité au Wi-Fi, lecture explicite toujours disponible en mobile.
- Tags : sélection de centaines de fichiers, ordre stable lors des coches,
  Monter/Descendre dans les actions VoiceOver du mode de réarrangement.
- Purger les miniatures pendant le défilement et les écritures de nouveaux
  fichiers : les nouveaux fichiers restent utilisables, aucune ancienne éviction
  ne les efface. Vérifier la taille après le ménage.
- Actualiser les récents pendant une vérification de fond : une vraie lecture
  réseau suit cette vérification. Déconnexion au même moment : pas de retour
  de la liste ni d’URLs de l’ancien compte.
- Un lot avec une grosse vidéo et plusieurs petits fichiers réutilise les
  places libérées ; annuler le lot puis relancer un fichier reste possible.

## Cache des miniatures, onglet Tag et menu de filtres — septembre 2026

- Miniatures : parcourir un dossier, revenir au premier plan après une coupure
  réseau brève. Une miniature déjà en cache s'affiche immédiatement, même si la
  demande précédente a échoué (le marqueur d'absence ne bloque plus la lecture
  disque). Un fichier dont le serveur refuse l'aperçu (404) cesse de réessayer
  pendant 5 minutes ; un simple délai réseau ou un 5xx retente après ~30 s.
  Réglages → « Miniatures enregistrées » doit croître pendant la navigation et
  « Vider le cache » repartir de zéro.
- Import d'une vidéo : le poster apparaît dans la fenêtre de réessais (~60 s)
  même si kDrive répond 404 les premières secondes ; aucune absence n'est
  mémorisée avant la fin de la fenêtre.
- Menu de filtres (Accueil, Favoris, corbeille, dossier, tag) : les
  orientations (portrait/paysage/carré) tiennent sur une seule ligne de logos
  (`ControlGroup` `.compactMenu`), idem pour Tout/Vidéos/Images/Dossiers/Autres
  (`Picker` `.palette`, défilement horizontal si étroit). L'option active se
  voit à la variante pleine du symbole ; un tap sur une orientation ne referme
  pas le menu, tap extérieur pour fermer. VoiceOver lit le nom de chaque logo
  et l'état sélectionné.
- « Fichiers uniquement » : masque les dossiers, y compris dans une recherche
  ou un tri ; le compteur d'éléments passe en « visibles » ; désactiver
  l'option (ou Réinitialiser) rend les dossiers. Vérifier qu'un filtre actif ne
  déclenche pas de pagination infinie quand la page suivante ne contient que
  des dossiers.
- Onglet Tag, sans ouvrir de tag : défilement de la grille et de la liste
  (grandes listes, Dynamic Type agrandi). Les cartes ne portent qu'une ombre
  minimale ; si une saccade subsiste en mode liste, soupçonner les actions de
  balayement (le menu contextuel long-press offre déjà Renommer/Supprimer).

Automatisation : `check_concurrency.py` vérifie le partage/annulation des
requêtes, la fenêtre glissante, les générations de purge, le décodage, la
capacité et l’expiration des URLs. `OrvianTests` (dont `PrivacyWindowTests`)
reste jouable en local via Xcode sur simulateur : protection d’une
présentation plein écran et disposition compacte du pavé, avec captures
clair/sombre dans le résultat XCTest. La publication sur `main` n'exécute plus
ces tests (durée des runs) ; ils restent disponibles via `checks.yml` sur les
pull requests et en local.

## Dossiers larges

- Ouvrir un dossier de plus de 60 éléments contenant images, vidéos et sous-dossiers.
- Vérifier le tri, la recherche et les filtres média sur cette longue liste.
