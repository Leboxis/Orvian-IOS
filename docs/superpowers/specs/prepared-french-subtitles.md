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

## Contexte précédent (révision 2)

Sur iOS 26.4+, chaque traduction reçoit la phrase courante et les phrases
précédentes dont la fin dépasse start − 8 secondes. La phrase chevauchant
la borne est gardée entière pour préserver le sens ; aucun texte futur n'est
fourni. Une requête AttributedString unique conserve les attributs Speech
audioTimeRange de chaque phrase. On extrait uniquement la traduction associée
à la phrase courante, sans modifier ses horaires ni réafficher le contexte.
Des attributs absents/inconnus ou une attribution ambiguë arrêtent la préparation
sans remplacer un cache complet. La version de cache passe à 2 sur iOS 26.4+
pour imposer un recalcul ; iOS 26.0–26.3 reste en version 1 et indique clairement
la traduction phrase par phrase. L'analyse Speech de l'audio reste inchangée.

## Parakeet Ultra

Prepared transcription now uses the explicitly selected Ultra Core ML model from FluidAudio 0.17.7, pinned at revision 503b4bd1bbf7220882de39fe8ae6716aae4132da. Live captions continue using Apple Speech. Translation remains Apple high-fidelity with eight seconds of previous sentence context on iOS 26.4+. No silent substitution of the transcription model.

Audio is extracted incrementally to protected 16 kHz mono PCM, retaining timeline gaps as silence. Ultra uses one concurrent window and disk-backed processing for long recordings. Cache versions 3/4 isolate Ultra results from older Apple transcriptions. Missing/inconsistent token times fail preparation instead of estimating subtitle times. No model or transcript logging. Initial model download is disclosed with attribution to Moondream/NVIDIA and Fluid Inference.

Validation: compile Release for iPhone and simulator; preserve existing tests; verify token text/timestamps, source timeline gaps, cache invalidation, and actual Ultra inference on a non-private synthetic fixture. Real iPhone memory/thermal performance remains device-dependent and requires on-device validation.

### Context attribute loss recovery

Apple documents attributed translation preservation as best effort. If context timing attributes are missing, merged or ambiguous, retry just the current original sentence via plain-text translation. Preserve the original Parakeet cue times, never save the entire translated context, and never substitute English for French. Report the number of isolated retries after completion and disclose this fallback in the preparation sheet. Cancellation and translation failures still propagate; empty retries cannot be saved. A valid contextual response continues to use the eight-second window.

Audio extraction explicitly closes its CAF writer before model loading, per AVAudioFile.close documentation. The PCM regression reads to end across partial reads and compares all 96,000 source samples with the decoded reference, retaining buffer ownership during pointer access.
