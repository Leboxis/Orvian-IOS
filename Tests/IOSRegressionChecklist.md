# Vérification iOS des corrections d'audit

Les tests automatisés s'exécutent sur le runner macOS, en mode Swift 5 :

```sh
python3 .github/scripts/check_ios_regressions.py
python3 .github/scripts/check_favorites_cache.py
```

Le build Xcode complet suit ces contrôles dans le workflow existant. Ces tests
utilisent des secrets factices et des transferts simulés, sans compte kDrive.

## Parcours à vérifier sur iPhone / simulateur

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
