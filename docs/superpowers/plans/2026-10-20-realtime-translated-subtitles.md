# Sous-titres anglais → français — faisabilité et plan d’implémentation

Date : 20 octobre 2026. **Statut : GO kDrive obtenu sur appareil (IPA `7b7d5453`) ; MVP promu en production (modes anglais/français, overlay, bouton CC, reprise automatique). Le panneau de diagnostic reste `#if DEBUG`.** Voir [la procédure et les limites du prototype](../../research/realtime-translated-subtitles-prototype.md).

## 1. Décision proposée

**GO pour un prototype borné sur les vidéos kDrive actuelles ; pas de promesse de compatibilité universelle.**

- Conserver `AVPlayer`, `AVPlayerLayer`, les commandes et le transport existants.
- Sur iOS 26, tester d’abord l’extraction audio du véritable fichier kDrive par `MTAudioProcessingTap` ; les modèles Speech et Translation ne résolvent pas à eux seuls l’accès au son.
- Sur iOS 27, tester aussi les sous-titres générés natifs documentés par Apple avant de réimplémenter leur chaîne. Retenir cette voie seulement si elle expose réellement les options anglais/français sur les sources et appareils cibles et s’intègre aux commandes personnalisées.
- Ne développer le MVP iOS 26 qu’après réussite du test audio → SpeechAnalyzer. Si ce test échoue sur kDrive, arrêter et présenter une alternative explicitement différente.

**Compromis produit :** sans anticipation ni retard de la vidéo, des sous-titres traduits stables ont nécessairement un retard sur la parole. « Quasi temps réel » est un objectif à mesurer, pas une garantie de synchronisation instantanée. Pour une vidéo à la demande, une analyse anticipée peut ensuite améliorer la synchronisation ; pour un direct, il faudrait accepter un retard des sous-titres ou décaler la vidéo, ce dernier choix étant hors MVP.

## 2. Ce que le dépôt confirme

| Constat | Conséquence |
|---|---|
| [Configuration du projet](../../../project.yml#L1-L10) : cible minimale iOS 26.0, Swift 5 | Pas besoin de relever la cible pour SpeechAnalyzer ; toute API iOS 27 doit être conditionnelle et demander le SDK correspondant. |
| [Rendu vidéo](../../../Orvian/Features/Viewer/VideoPlayerSupport.swift#L58-L85) : AVPlayerLayer, pas AVPlayerViewController | Ajouter les commandes au chrome existant ; ne pas remplacer le lecteur pour obtenir un bouton natif. |
| [Préparation des assets](../../../Orvian/Core/Media/VideoAssetCache.swift#L27-L62) : AVURLAsset sur URL HTTPS signée | Bonne candidate pour un média fichier distant ; le code ne prouve ni le conteneur réellement servi, ni l’accès PCM. |
| [Résolution d’URL](../../../Orvian/Core/Media/MediaURLCache.swift#L32-L62) : URL temporaire, isolée par compte | Réutiliser cette résolution ; ne jamais transmettre le jeton à un fournisseur IA ou journaliser une URL signée. |
| [Création du player item](../../../Orvian/Features/Viewer/VideoPlayerView.swift#L1090-L1157) centralisée | Point de raccordement du tap et de la session de sous-titres ; pas de refonte globale. |
| [Seek](../../../Orvian/Features/Viewer/VideoPlayerView.swift#L932-L986), [récupération](../../../Orvian/Features/Viewer/VideoPlayerView.swift#L1197-L1228), [destruction](../../../Orvian/Features/Viewer/VideoPlayerView.swift#L1360-L1395) déjà gérés | Les sous-titres doivent suivre ces événements et invalider leurs anciennes tâches. |
| [Horloge UI](../../../Orvian/Features/Viewer/VideoPlayerView.swift#L1231-L1258) : l’état de temps n’est plus publié lorsque les contrôles sont masqués | Ne pas piloter les sous-titres avec cette seule horloge ; ils doivent continuer à évoluer chrome masqué. |

Aucun parcours HLS/direct explicite n’a été trouvé dans le lecteur inspecté. Cela ne prouve pas le format des réponses kDrive : le prototype doit l’observer sans présumer qu’une extension d’URL décrit le média.

## 3. Matrice de viabilité

| Source / système | Conclusion documentaire | Décision MVP |
|---|---|---|
| Fichier MP4/MOV local non protégé, iOS 26 | `AVAudioMix` + `MTAudioProcessingTap` constituent la piste native file-based | Contrôle positif du prototype. |
| Fichier distant progressif via URL kDrive, iOS 26 | Candidat file-based ; comportement exact dépend du média et du service | Cas principal à prouver avec l’URL signée réelle, sans téléchargement intégral préalable. |
| HLS VOD ou live, iOS 26 | Apple exclut HLS de `AVPlayerItem.audioMix` [A1] | Hors support de cette voie ; ne pas annoncer qu’un tap suffira. |
| HLS, iOS 27 | `AVPlayerItemSampleBufferOutput` fournit du PCM décodé ; API introduite en 27.0 et actuellement HLS seulement [A2] | Piste séparée si nécessaire, après test de la solution native intégrée. |
| Sous-titres générés système, iOS 27 | Apple documente transcription anglaise et traduction depuis des sous-titres anglais, sur fichiers et HLS [A3] | Évaluer en premier sur iOS 27 ; confirmer le français et le chemin audio anglais sans piste texte préexistante. |
| DRM / contenu protégé | Aucune garantie d’accès PCM établie dans cette étude | Exclu du pipeline personnalisé initial ; aucune tentative de contournement. |
| AirPlay / PiP | Un overlay SwiftUI local n’est pas une piste de sous-titres transportée | Ne pas promettre l’affichage distant ; désactiver ou signaler la limite, sans casser AirPlay. |

Les disponibilités matérielles et linguistiques doivent être interrogées à l’exécution ; iOS 26 installé ne signifie pas automatiquement SpeechTranscriber disponible [A4]. Aucun recours au microphone, au loopback système ou à un serveur de transcription n’est prévu.

## 4. Lot 0 — Test de faisabilité obligatoire

### 0A. Évaluation courte de la voie native iOS 27

- [ ] Sur un appareil iOS 27 et SDK adapté, inspecter les options de sous-titres réellement exposées par AVFoundation sur une vidéo anglaise locale puis kDrive, avec et sans sous-titres préexistants. Utiliser aussi `AVPlayerItem.selectableMediaSelectionOptions(in:)` pour filtrer les options réellement productives selon la piste audio sélectionnée, plutôt que supposer que toutes les entrées du groupe sont utilisables [A7].
- [ ] Vérifier anglais puis français, préparation des modèles, refus de téléchargement, pause, seek, lecture muette et commandes personnalisées AVPlayerLayer.
- [ ] Vérifier que le système permet de respecter les trois choix demandés et de placer les sous-titres sans recouvrir le transport. Ne pas supposer que « disponible automatiquement » dans AVKit ajoute un menu au lecteur personnalisé.
- [ ] Si cette voie suffit et que l’on accepte un support fonctionnel limité à iOS 27, arrêter ici l’effort de pipeline personnalisé. Conserver la lecture normale et un état explicite sur iOS 26.

Cette évaluation ne remplace pas la preuve audio demandée si l’on maintient l’objectif iOS 26.

### 0B. Preuve audio → SpeechAnalyzer sur le lecteur actuel, iOS 26

- [ ] Ajouter une instrumentation de développement temporaire, désactivée hors test. Aucun bouton public annonçant une fonctionnalité opérationnelle à ce stade.
- [ ] Utiliser une fixture anglaise connue (MP4/MOV AAC ou PCM) comme contrôle local, puis au moins trois vidéos kDrive représentatives, dont une longue.
- [ ] Au point de création d’AVPlayerItem, charger les pistes audio et les propriétés de protection ; classifier la source autrement que par la seule extension du nom.
- [ ] Installer un tap pass-through sur la piste anglaise sélectionnée via AVMutableAudioMixInputParameters. Ne modifier ni échantillons ni volume ni catégorie audio `.playback`.
- [ ] Dans le callback temps réel, appeler MTAudioProcessingTapGetSourceAudio et copier seulement dans une réserve préallouée/bornée. Aucun appel Speech/Translation, Task par buffer, attente, réseau ou allocation lourde sur ce callback.
- [ ] Sur un worker, convertir les buffers avec AVAudioConverter vers SpeechAnalyzer.bestAvailableAudioFormat, conserver le timing média en tenant compte du priming de conversion et alimenter AnalyzerInput avec des timestamps monotones. Ne pas utiliser sans garde les helpers AnalyzerInputConverter / AssetInputSequenceProvider, introduits en iOS 27.
- [ ] Vérifier SpeechTranscriber.isAvailable, la locale anglaise et les assets avant de démarrer. Installer les assets avec un état visible et annulable ; pas de fallback serveur silencieux.
- [ ] Consommer les résultats dans une tâche séparée : journaliser uniquement compteurs, durées et résultat de la fixture de test, pas les paroles privées de l’utilisateur.
- [ ] Mesurer le temps depuis les échantillons parlés jusqu’aux résultats partiels puis définitifs, la stabilité de la mémoire, CPU/thermique et les éventuelles coupures audio.
- [ ] Tester pause/reprise, mute, seek avant/arrière, vitesses 0,5× à 2×, masquage des contrôles, changement de page, fermeture, interruptions et reconstruction après erreur réseau.

### Porte de décision GO / NO-GO

**GO uniquement si** :

1. Le lecteur kDrive réel fournit des buffers PCM sans microphone ni téléchargement complet préalable, et l’audio original continue normalement.
2. Les paroles anglaises de la fixture produisent du texte correct via SpeechAnalyzer ; un simple callback audio non vide ne suffit pas.
3. Aucun callback périmé n’apparaît après seek, changement de vidéo ou démontage ; les tâches et buffers sont libérés.
4. Une lecture de 15 minutes ne montre ni croissance continue des files/mémoire ni dégradation audio imputable au prototype.
5. Les mesures de latence permettent une décision produit. Budget exploratoire après installation des modèles : traduction visible généralement en 2–4 s, p95 inférieur à 6 s sur le corpus convenu ; **ce sont des seuils proposés, pas une performance constatée ou garantie par Apple**.

Le dernier budget sera mesuré de bout en bout au lot 2 ; au lot 0, relever séparément le coût de la transcription et réserver un budget à la traduction. Si le tap fonctionne seulement sur le contrôle local et pas sur kDrive, le cas principal reste **NO-GO**.

En cas d’échec : rapport avec cause et preuves ; pas de reconstruction du lecteur ou ajout automatique de FFmpeg. Un téléchargement local préalable pourrait constituer un mode distinct pour des fichiers VOD, mais change le délai, la bande passante et l’objectif de streaming ; demander validation avant de le développer. AVAssetReader n’est pas un accès universel au PCM rendu par AVPlayer ni un correctif automatique au cas HLS [A1, A2].

## 5. Lot 1 — Transcription anglaise et synchronisation

À engager seulement après GO du lot 0B, sauf choix exclusif de la voie système.

### Frontières minimales

Nouveaux éléments proposés, à créer uniquement si le pipeline personnalisé est nécessaire :

- `PlayerAudioTap` : durée de vie du tap, copie bornée et horodatage ; aucun état SwiftUI.
- `VideoSubtitleSession` : propriétaire unique des tâches Speech/Translation, conversion audio et état de session.
- `SubtitleCue` / `SubtitleTimeline` : segments temporisés et règles testables sans appareil.
- `VideoSubtitleOverlay` : affichage observant uniquement le sous-titre actif.

Pas d’interface multi-fournisseurs ni de deuxième transport vidéo. Le lecteur existant fournit ses événements au propriétaire des sous-titres.

### Règles

- [x] Produire des segments identifiés par fichier, génération et intervalle média ; remplacer les résultats volatils, ne pas les ajouter indéfiniment.
- [x] Utiliser `.timeIndexedProgressiveTranscription` et les plages audio des résultats [A4]. Conserver une correspondance explicite entre timeline de l’analyseur et timeline du média.
- [x] Après seek/discontinuité, démarrer une nouvelle génération et, si nécessaire, un nouvel analyseur : ne pas envoyer des timestamps qui reculent ou se recouvrent dans la session existante [A5]. La nouvelle origine est la position effectivement atteinte, pas seulement la position demandée.
- [x] Pour pause/buffering, geler l’avancement des sous-titres sur la position du média ; éviter une accumulation d’audio non bornée. Conserver le segment courant si pertinent.
- [x] Pour les résultats en retard, appliquer une politique explicite d’affichage différé borné ; ne pas supprimer systématiquement chaque segment dont l’intervalle source est déjà passé, sinon le mode live resterait vide. Après seek, ne jamais rejouer les sous-titres de l’ancienne génération.
- [x] Piloter l’affichage avec le temps AVPlayer même commandes masquées, sans rafraîchir toute la vue vidéo à chaque échantillon. Retirer tout observateur au démontage.
- [ ] Tester l’association temporelle à chaque vitesse ; ne pas assimiler arbitrairement secondes de média et secondes murales (MVP 1× seulement).
- [x] Finaliser explicitement l’analyseur en fin de média ; à la désactivation/fermeture/remplacement, annuler et libérer via un chemin unique.

## 6. Lot 2 — Traduction anglais → français

- [x] Vérifier LanguageAvailability : installed / supported nécessitant téléchargement / unsupported [A6]. Ne télécharger qu’après une action et un consentement utilisateur adaptés.
- [x] Préparer les langues manquantes dans le cycle de vie SwiftUI `.translationTask` / prepareTranslation. Une fois installées, iOS 26 permet aussi TranslationSession(installedSource:target:) ; ne jamais réutiliser une session SwiftUI après disparition de sa vue ou changement de configuration : Apple documente un fatalError [A6].
- [x] Traduire d’abord les segments définitifs, éventuellement regroupés en courte unité cohérente. Exploiter les partiels pour l’anglais mais pas pour retraduire chaque mot.
- [x] Si les définitifs sont trop tardifs, mesurer une stratégie de stabilisation bornée avant de l’adopter ; stabilité et délai font l’objet d’un arbitrage explicite.
- [x] Une file séquentielle bornée suffit au MVP. Dédupliquer par génération/segment/révision, rejeter les retours périmés, borner les résultats en mémoire et rattraper le présent plutôt qu’empiler un historique en retard.
- [x] En cas d’erreur, afficher une explication non bloquante ; conserver la lecture, proposer l’anglais si disponible, ne pas changer silencieusement le mode français choisi.
- [ ] Relever latence transcription, segmentation, traduction et affichage séparément, modèles froids et chauds. Confirmer le budget exploratoire du lot 0 ou réviser le périmètre avec l’utilisateur.

L’audio et le texte de cette chaîne restent sur l’appareil ; le téléchargement de la vidéo et des modèles nécessite toujours du réseau lorsqu’ils ne sont pas déjà disponibles. Pas de stockage persistant des transcriptions au MVP.

## 7. Lot 3 — Commandes et overlay

- [x] Ajouter « CC / Traduction » dans les contrôles personnalisés iPhone et iPad : Désactivés / Anglais (transcription) / Français (traduction automatique).
- [x] Afficher états préparation, modèle manquant, source incompatible et erreur avec raison compréhensible ; activation/désactivation sans pause forcée du média.
- [x] Garder les commandes visibles pendant le menu, puis réutiliser la logique existante d’auto-masquage.
- [x] Positionner un overlay non interactif au-dessus du transport, adapté aux dimensions réelles, safe areas, paysage et Dynamic Type ; le laisser visible quand les commandes disparaissent.
- [x] Assurer contraste, taille lisible, libellé/valeur VoiceOver du bouton ; éviter l’annonce forcée de chaque mot et ne pas rendre les sous-titres inaccessibles via l’accessibilityElement global de la zone vidéo.
- [x] Préserver mute, gestes ±10 s, pager, favoris, tags et vitesse. Réutiliser le verrou de geste des contrôles existants.
- [x] Ne modifier ni ordre des onglets ni paire Hasard/Sélectionner, protégés par [les instructions du dépôt](../../../AGENTS.md).

## 8. Lot 4 — Preuves et déploiement progressif

- [x] Tests de timeline : chevauchement partiel/final, traduction tardive, ordre des réponses, pause, seek et vitesse ; mémoire/file bornées et suppression des générations obsolètes.
- [x] Tests de cycle de vie : ON/OFF répété, fermeture, changement de fichier/compte, échec de modèle, téléchargement refusé, absence de piste anglaise, piste muette et format non compatible.
- [ ] Tests sur appareil iPhone et iPad : local et kDrive, écouteurs/mute, réseau lent, URL signée expirée et récupération, 15 minutes de lecture continue, consommation thermique.
- [x] Vérifier les chemins AirPlay existants. Hors support des sous-titres générés par notre overlay : dire pourquoi, préserver la vidéo. Ne pas ajouter PiP au titre de cette fonctionnalité.
- [x] Exécuter les contrôles de transport existants, les tests Python de non-régression, dont le test de navigation protégée, et les nouveaux tests iOS ciblés.
- [x] Activation de la fonctionnalité sur les seules sources/appareils validés ; toute source incompatible garde la lecture standard.

### Défauts corrigés après retours sur l'IPA de la branche diagnostics

Trois causes empêchaient les sous-titres français d'apparaître alors que l'anglais fonctionnait :

1. **Le cue traduit gardait l'instant de parole.** La traduction arrivant plusieurs secondes après la parole, `refresh` le jugeait aussitôt plus vieux que `maximumAge` et ne l'affichait jamais. Il est désormais ancré sur la position lue au moment de son arrivée. Test verrouillé dans `Tests/test_subtitle_cues.py`.
2. **Aucun contrôle d'installation.** `TranslationSession(installedSource:target:)` exige les deux langues déjà installées et rejette sinon chaque appel ; `LanguageAvailability` n'était interrogé nulle part. La disponibilité est maintenant vérifiée avant création de session, et le message distingue « modèle absent » d'un simple échec.
3. **Aucun repli ni diagnostic.** Le mode français ne retombait pas sur l'anglais et n'affichait ni la préparation ni l'erreur — écran vide sans explication. L'overlay montre ces états et retombe sur l'anglais.

Deux autres défauts de production ont été corrigés au passage : les arrêts de capture (seek, scrub, vitesse, arrière-plan, fermeture du lecteur) n'existaient que sous `#if DEBUG`, donc inactifs dans l'IPA Release ; et le compteur anti-boucle de relance était remis à zéro par chaque arrêt technique, ce qui annulait le plafond de sécurité.

**Limites de la présente étude :** environnement Windows, aucun build Xcode, aucun test sur appareil/simulateur, aucune URL kDrive authentifiée consultée. Aucun test visuel ni capture via GitHub Actions. Les preuves de performance et d’accès au PCM restent à produire sur Mac + appareil réel.

## 9. Sources officielles structurantes

- **[A1]** [AVPlayerItem.audioMix](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix) — file-based uniquement, exclusion HLS ; [JSON Apple consulté](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritem/audiomix.json). [audioTapProcessor](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/audiotapprocessor).
- **[A2]** [AVPlayerItemSampleBufferOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemsamplebufferoutput) — PCM décodé HLS, gestion de timebase au client ; [JSON Apple, disponibilité iOS 27.0](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritemsamplebufferoutput.json).
- **[A3]** [WWDC26 — Discover generated subtitles and subtitle styles](https://developer.apple.com/videos/play/wwdc2026/256/) — génération locale, fichiers/HLS et langues ; disponibilité iOS 27.
- **[A4]** [WWDC25 — SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) — traitement local, résultats temporels et assets.
- **[A5]** [AnalyzerInput](https://developer.apple.com/documentation/speech/analyzerinput) — contrat temporel des buffers ; [permissions Speech](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition) — distinguer SFSpeechRecognizer et SpeechAnalyzer, pas de capture microphone dans ce projet.
- **[A6]** [TranslationSession](https://developer.apple.com/documentation/translation/translationsession), [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability), [translationTask](https://developer.apple.com/documentation/swiftui/view/translationtask(_:action:)) — langues installées, préparation et durée de vie des sessions.
- **[A7]** [selectableMediaSelectionOptions(in:)](https://developer.apple.com/documentation/avfoundation/avplayeritem/selectablemediaselectionoptions(in:)) — options utilisables selon la sélection audio ; [JSON Apple, disponibilité iOS 27.0](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritem/selectablemediaselectionoptions(in:).json).

Pour les détails de vérification documentaire : [note de recherche Apple](../../research/realtime-translated-subtitles-apple-feasibility.md).
