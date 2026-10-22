# Sous-titres français préparés

## Objectif et critères

Une action « Préparer les sous-titres français » apparaît dans le menu d’appui long
des vidéos actives. Une feuille permet de choisir la langue réellement parlée,
de préparer/recalculer, annuler ou supprimer les sous-titres, puis fermer la
feuille pour ouvrir la vidéo avec le geste habituel.
Le traitement reste local : aucun nouveau service, clé API ou facturation.
La préparation complète peut demander le téléchargement de toute la vidéo et
des modèles ; l’application doit rester au premier plan.

Le décodage conserve les horodatages média des échantillons. SpeechTranscriber
travaille sans résultats rapides/provisoires ; seuls les résultats définitifs sont
conservés. Les phrases complètes sont traduites séquentiellement sans abandon
en cas de lenteur. Sur iOS 26.4+, demander la stratégie Apple highFidelity
(disponibilité des modèles gérée par Apple, repli système possible).

Un résultat n’est publié qu’une fois entièrement réussi. Les traductions sont
associées aux intervalles source et conservées localement par compte, drive,
fichier, révision et langue. Une vidéo préparée s’ouvre avec le français prêt ;
le menu CC permet toujours de désactiver ou d’afficher l’original. Aucun moteur
Speech/Translation ne fonctionne pendant cette lecture. Les recherches avant /
arrière, pauses et changements de vitesse utilisent les mêmes horodatages.
Aucune avance de 0,5 s ni ancrage à l’arrivée des résultats : start <= time < end.
L’observateur média vérifie les transitions à 20 Hz sans publier à chaque tick.

## Structure et style

Core/Media : modèle Codable, cache actor, analyseur actor.
Features/Viewer : feuille et orchestration MainActor ; la grille reste propriétaire
unique de sa présentation, comme les autres actions du menu.
Features/Viewer : sélection des cues préenregistrés, distincte du mode temps réel.
Modèles valeur Sendable, opérations lourdes hors MainActor, erreurs affichables
sans URL signée ni transcription privée dans les logs.

## Validation et commandes

- `python3 -m unittest discover -s Tests -p test_protected_navigation.py`
- `python3 -m unittest discover -s Tests -p test_phone_video_player.py`
- `xcodegen generate`
- `xcodebuild -project Orvian.xcodeproj -scheme Orvian -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
- Tests iOS ciblés PreparedSubtitleTests et SubtitleQualityTests sur simulateur.

Tester les bornes temporelles, silences, recherches, découpage des phrases,
ordre des traductions, cache versionné, isolation entre comptes et refus d’un
résultat incomplet. Compiler les nouvelles API Speech/Translation avec Xcode.
La qualité linguistique et la fidélité des horodatages reconnus sont à mesurer
sur iPhone avec des vidéos représentatives ; elles ne sont pas garanties par
les seuls tests de sélection temporelle.

## Limites et invariants

Toujours : annulation/nettoyage, cache borné/protégé, aucune vidéo source
persistée après préparation, aucune reprise d’un résultat d’un autre compte,
aucun texte anglais de repli en mode français.
Ne jamais : modifier les onglets/boutons protégés, lancer des captures/contrôles
visuels dans Actions, annoncer une précision parfaite du moteur automatique.
Ne pas ajouter de service cloud ou de dépendance sans demande explicite.
