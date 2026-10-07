# Tri local avec NudeNet 320n et JoyTag

Date : 7 octobre 2026. Choix des deux modèles confirmé par l'utilisateur.

## Objectif

Réutiliser le scan du dossier pour classer les images en « Nudité / sperme »,
« Pieds » ou « Aucun ». « À analyser » reste distinct et inclut les erreurs.
L'utilisateur ne dispose pas de données d'entraînement : utiliser les poids
publics existants, sans entraînement ni service d'analyse distant.

## Modèles et traitement

- NudeNet 320n, poids v3.4 : détection de zones de nudité et de pieds nus.
  Reproduire le carré noir avec padding à droite/en bas, RGB, 320 × 320,
  valeurs divisées par 255, classes gagnantes puis NMS de référence.
- JoyTag, poids `6b7f16331a6ccf0fdce37d5a9564715f6e772b22` : utiliser le
  tag `cum` pour le sperme. Carré blanc centré, RGB, 448 × 448 ; normalisation
  CLIP incorporée au modèle ; sigmoid indépendant, jamais softmax.
- Exports Core ML ML Program fp16 avec entrées images et sorties fp32.
  Les poids et sources téléchargés sont verrouillés par révision et SHA-256.
- Exécution séquentielle dans l'actor existant, hors MainActor. Décodage orienté
  une seule fois, padding spécifique à chaque modèle sans center crop.

## Résultats et interface

Conserver trois scores : nudité, sperme, pieds. Le score de contenu explicite
est le maximum des deux premiers. Au seuil réglable, priorité à « Nudité /
sperme », puis « Pieds », puis « Aucun ». Un résultat n'est enregistré que si
les deux inférences ont réussi et si tous les scores sont finis dans [0, 1].
Seuil initial 0,50, réglable de 0,30 à 0,99, au-dessus du minimum NudeNet
(scores > 0,25 conservés avant NMS) ; il reste à calibrer sur des photos.
Les scores des deux modèles ne constituent pas des probabilités exclusives.

Le stockage conserve son isolation compte/drive/révision. Une nouvelle version
du pipeline invalide les anciens scores Marqo ; les anciennes entrées doivent
rester décodables mais ne sont jamais interprétées comme « Aucun ».
Ajouter les trois choix aux filtres partagés et aux compteurs de progression.
La navigation, la pagination et l'annulation gardent leurs règles existantes.

## Distribution et validation

Les modèles générés ne sont pas committés : la CI macOS les exporte, vérifie
leurs sorties contre PyTorch/ONNX puis transmet les mêmes packages au job IPA.
La compilation doit échouer si l'export ou sa vérification échoue.
Documenter la commande locale macOS, les licences et les limites.

Tests : invalidité/absence des scores, seuil et priorité, pieds seuls,
persistance des trois scores, invalidation Marqo, erreurs/annulation du scan,
prétraitement portrait/paysage et orientation, NMS et ordre des classes,
inférence native sur images synthétiques et parité numérique fp16.
Mesures de précision réelle, RAM et latence sur iPhone restent à effectuer.

## Portée

Analyse du contenu direct du dossier, filtres locaux ; aucun déplacement de
fichiers, aucune récursion ni analyse vidéo. NudeNet ne détecte pas le sperme.
JoyTag est principalement entraîné sur des illustrations : les résultats sur
photographies doivent être évalués. Le padding natif et celui de Pillow/OpenCV
peuvent différer légèrement en interpolation ; ne pas prétendre à une parité
pixel par pixel avant mesure.
