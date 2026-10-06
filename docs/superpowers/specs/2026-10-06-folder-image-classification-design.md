# Analyse SFW / NSFW du dossier actuel

Date : 6 octobre 2026
Statut : périmètre et plan approuvés en conversation ; implémentation locale préparée, validation native iOS en attente.

## Objectif et demandes confirmées

L'utilisateur souhaite classer les images SFW / NSFW et filtrer la grille
à partir de ces résultats. Un bouton dédié lance le scan dans le dossier
actuellement ouvert. Les images restent affichées normalement.

L'analyse utilise Marqo/nsfw-image-detection-384 converti en Core ML,
exécuté localement avec Vision. Aucun service de classification distant
n'est ajouté. Les images absentes du cache sont récupérées depuis kDrive.

## Fonctionnement proposé

- Un bouton de barre d'outils, accessible sous le nom « Scanner ce dossier »,
  lance immédiatement l'analyse des images du dossier courant.
- L'identité du compte, le drive et l'identifiant du dossier sont capturés
  au lancement : changer la recherche ou les filtres ne change pas la portée.
- Toutes les pages du dossier sont parcourues, y compris celles qui ne sont
  pas encore chargées à l'écran. Les sous-dossiers ne sont pas parcourus.
- Le scan concerne les fichiers reconnus comme images. Une miniature de GIF
  représente uniquement une image fixe ; le scan ne certifie pas son animation.
- Le bouton ouvre la progression si un scan est déjà en cours. Un seul scan
  est actif à la fois dans l'app, avec son nom de dossier clairement affiché.
- La présentation de progression propose « Annuler » et affiche les nombres
  d'images classées SFW, NSFW et en erreur. Pendant l'énumération, elle indique
  « Recherche des images » ; le total devient déterminé après l'énumération.
- Les résultats déjà obtenus restent disponibles après une annulation.
- Le scan s'arrête si l'app passe en arrière-plan ou si le compte actif change.
  Fermer la présentation ou consulter un autre dossier au premier plan ne
  change pas le dossier analysé. Un nouveau lancement réutilise les résultats
  encore valides et traite les images restantes.
- Une erreur d'énumération rend le scan explicitement incomplet. Une erreur
  sur une image n'empêche pas l'analyse des autres images.

## Classement et filtres

Le menu de filtres partagé propose « Tous », « SFW », « NSFW » et
« Non analysés ». Choisir un filtre de classification active le type Images
et retire les critères propres aux vidéos. Choisir un autre type de média
réinitialise le filtre de classification. « Tous » retrouve le comportement
normal des filtres existants.

La grille et la visionneuse utilisent les mêmes règles. Un résultat nouveau
invalide la mémoïsation des éléments visibles. Le filtre combine les résultats
locaux, la recherche et le tri ; il ne devient pas un filtre serveur kDrive.
Le lancement du scan est indépendant des éléments actuellement visibles.

Une image sans résultat valide, y compris après un échec, reste « Non analysée ».
SFW désigne une classification du modèle, sans garantie de contenu inoffensif.
La valeur NSFW et le seuil sont conservés séparément : le seuil est réglable
dans la présentation de scan, avec une valeur initiale de 0,80 à valider sur
des images représentatives. Changer le seuil reclasse les scores sans inférence.

## Intégration technique

1. Un service Core ML / Vision charge une seule instance du modèle et effectue
   les inférences hors du MainActor, avec une concurrence initiale de un.
2. Un coordinateur observable gère l'énumération paginée via KDriveService,
   la progression, l'annulation et l'association au compte actif.
3. Un stockage local conserve les scores, sous une clé isolée par compte,
   drive, fichier, version du fichier et version du modèle. Les horodatages
   disponibles et la taille identifient conservativement une révision.
   Une révision inconnue ne permet pas de réutiliser un résultat persistant.
4. ThumbnailProvider fournit les images au classifieur. Lorsqu'une nouvelle
   inférence est nécessaire, un chemin dédié récupère les octets actuels du
   serveur et évite le cache de miniatures, qui n'est pas indexé par révision.
   Un score encore valide évite ce téléchargement et l'inférence.
5. DirectoryView reçoit le bouton et la présentation du scan. FileFilters,
   FilterMenu et les consommateurs du filtrage reçoivent les résultats locaux.
   Le dossier racine reçoit le même bouton dans sa vue de contenu existante.

Le modèle est embarqué avec l'app : le fonctionnement ne dépend pas d'un
téléchargement de modèle au premier lancement. Son origine, sa révision et
les attributions de licence sont documentées. L'orientation, le redimensionnement
et la normalisation reproduisent le prétraitement de référence. La conversion
macOS proposée doit être vérifiée pour la cible iOS avant d'être retenue.

La conversion de NSFWScanner examinée au commit
`c8ff10d90d80e3d4f65d75b9a745a529c2defb78` trace directement les logits
de Marqo ; son script de vérification leur applique ensuite un softmax.
La conversion embarquée par Orvian doit donc produire de vraies probabilités
avant l'application du seuil, avec un softmax explicite dans le modèle.

## Vérifications attendues

- Énumération complète d'un dossier multipage, avec dossiers et fichiers mixtes,
  dédoublonnage et arrêt sur un curseur qui ne progresse pas.
- Annulation, relance, absence de double scan et changement de compte pendant
  une requête : aucun résultat ne rejoint le mauvais compte.
- Persistance et invalidation après modification de fichier ou changement
  de version du modèle ; absence de classification SFW sur les erreurs.
- Combinaisons des filtres, recherche, réinitialisation et cohérence de la
  visionneuse ; résultats reçus pendant qu'un filtre est actif.
- Comparaison des sorties Core ML et du modèle de référence sur des images
  représentatives et mesure de la latence / mémoire sur iPhone.
- Compilation iOS avec le modèle réellement embarqué. Le poste Windows
  ne possède pas Xcode ; la compilation et les vérifications Core ML natives
  nécessitent macOS / la CI, et les mesures d'usage nécessitent un iPhone.

## Limites de cette première version

La portée est le contenu direct du dossier actuel. L'analyse des vidéos,
la récursion, le scan automatique, la synchronisation de classifications
vers les tags kDrive et les actions de déplacement ne font pas partie de
cette version. Les miniatures peuvent limiter la précision : celle-ci doit
être évaluée avant de présenter cette version comme prête à utiliser.
