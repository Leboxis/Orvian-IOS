# Sous-titres vidéo anglais → français locaux : faisabilité Apple

Recherche documentaire du **20 octobre 2026**, pour une application dont le deployment target est **iOS 26**. Cette note n’implémente rien : aucune modification de code applicatif, aucun build, test, simulateur ni CI. L’inspection de l’architecture Orvian est conduite séparément ; les points de raccordement ci-dessous sont un plan, pas un constat d’implémentation.

## Verdict

**Faisable sous conditions sur iOS 26 pour les médias de type fichier non protégés :** récupérer une copie de l’audio du `AVPlayerItem` existant via `AVMutableAudioMixInputParameters.audioTapProcessor` / `MTAudioProcessingTap`, transcrire avec `SpeechAnalyzer` + `SpeechTranscriber`, puis traduire les phrases anglaises avec `TranslationSession`. Les deux traitements linguistiques peuvent rester sur l’appareil, après installation de leurs modèles respectifs. **Ce n’est pas une solution générale HLS sur iOS 26.** [A][B][S][T]

**La nouveauté audio ne doit pas être antidatée :** `AVPlayerItemSampleBufferOutput` et `AVPlayerItemSampleBufferOutputAudioConfiguration` existent dans la documentation Apple consultée, mais leurs métadonnées indiquent **iOS 27.0**, et leur prise en charge actuelle concerne **HLS uniquement, PCM décodé uniquement**. Elles ouvrent une seconde voie conditionnelle sur les appareils exécutant iOS 27, sans obliger à relever le deployment target ; elles ne résolvent pas le cas des appareils restés sous iOS 26. [C][D]

**Avant un pipeline custom iOS 27, examiner aussi les sous-titres générés natifs Apple :** Apple annonce une génération locale anglais audio → anglais texte, et une traduction de sous-titres anglais vers d’autres langues, pour HLS live/VOD et médias fichier. La disponibilité précise du français, des appareils et des conditions DRM n’est pas démontrée par les passages consultés : cette piste n’est pas une promesse de couverture EN → FR universelle. [N]

### Degrés de certitude

- **Confirmé** : contrat explicitement présent dans une source primaire Apple, lue directement, dont les JSON DocC pour les pages JavaScript.
- **Déduction / hypothèse de conception** : conclusion raisonnable ou architecture proposée à partir de ces contrats, sans validation d’exécution.
- **Inconnu / à mesurer** : absence de garantie dans les sources consultées, ou comportement dépendant du média/appareil. L’absence de preuve n’est pas transformée en interdiction absolue.

## 1. Accès à l’audio du lecteur existant

### Matrice des sources

| Source | iOS 26 : audio mix + tap | iOS 27 : nouvelle sortie de sample buffers | Niveau de preuve / décision |
|---|---|---|---|
| Fichier local MP4/MOV lisible, non protégé | Voie documentée pour les médias fichier ; exemple Apple de tap sur vidéo locale. | La nouvelle sortie est documentée HLS seulement, pas comme remplacement universel du tap. | **Confirmé pour la catégorie fichier** ; formats, piste et contenu réels à valider. [A][B][C][E] |
| MP4 distant progressif, non protégé | Candidat raisonnable si AVFoundation le traite comme média fichier, et non HLS. | Pas de support fichier annoncé pour cette sortie. | **Déduction** du contrat « file-based media » : les pages consultées ne garantissent pas chaque serveur/URL distante ; à prouver sur les URL réelles. [B][C] |
| HLS VOD | `audioMix` explicitement non pris en charge pour HLS. | Sortie PCM HLS documentée. | **Confirmé** ; ne pas confondre VOD et fichier progressif. [B][C] |
| HLS live | Même exclusion HLS ; pas d’exception live. | Catégorie HLS documentée ; contraintes live, fenêtre de seek et discontinuités à tester. | Exclusion iOS 26 **confirmée** ; robustesse live non mesurée. [B][C] |
| HLS téléchargé pour lecture hors ligne | Ne pas supposer qu’un téléchargement transforme l’asset HLS en MP4 fichier compatible `audioMix`. | Contrat à vérifier sur l’asset téléchargé réel. | **Inconnu pour cette variante**, exclue d’une garantie MVP. [B][C] |
| Contenu protégé / DRM / FairPlay | Aucune garantie de remise du PCM protégé trouvée dans les pages tap/mix consultées. | La page de la nouvelle sortie ne précise pas les autorisations/exclusions DRM. | **Support non établi**, hors MVP ; ne jamais confondre droit de lecture et droit d’accès aux échantillons. [A][B][C][F] |

**Preuve décisive HLS :** la documentation `AVPlayerItem.audioMix` dit : « An audio mix can only be used with file-based media and is not supported for use with media served using HTTP Live Streaming. » Cette limite touche le chemin tap attaché au mix du lecteur ; elle n’affirme pas qu’aucune API Apple actuelle ne sait jamais traiter HLS. [B]

`audioTapProcessor` permet d’associer le tap à une piste audio et d’accéder à l’audio avant lecture, lecture des données ou export. Il ne capture ni le microphone ni arbitrairement le son des autres applications. [A]

### Contrat mémoire et horodatage du tap

**Confirmé :** `MTAudioProcessingTapGetSourceAudio` ne se rappelle que depuis le callback du tap. Il fournit un `CMTimeRange` correspondant au temps de l’asset, le nombre de frames réellement obtenu et des flags de discontinuité/fin. Si les pointeurs de buffers sont fournis par le système, leur validité ne dépasse pas la durée du callback. [G]

**Conséquence de conception :** copier dans une mémoire possédée par l’application avant de sortir du callback ; déposer dans une file bornée ; faire conversion, ASR et traduction hors du callback. Ne pas y lancer une tâche lourde, attendre un actor, effectuer une requête de modèle ou conserver un pointeur emprunté. La politique de saturation doit être explicite : interrompre proprement la génération ou signaler/recréer une séquence après perte, plutôt qu’accumuler indéfiniment du retard.

Le lecteur et sa restitution audio restent la source de vérité. Le tap doit préserver le signal joué, le mix existant et les paramètres de piste ; l’ASR est une branche d’analyse, pas un second lecteur. **À valider :** piste effectivement sélectionnée, multi-audio, mapping exact des timestamps après composition, changement de vitesse, time-stretch et choix pré-/post-effets. Les contrats consultés ne suffisent pas à garantir automatiquement ces combinaisons. [A][G]

### Nouvelle API iOS 27 : faits précis

**Confirmé :** créer `AVPlayerItemSampleBufferOutput` avec une configuration audio puis l’attacher au même `AVPlayerItem` permet d’obtenir l’audio décodé dans le format demandé. L’item doit être l’item courant de son lecteur. La sortie peut livrer des buffers très en avance ; le client doit borner cette avance en observant la timebase du lecteur. Des buffers marqueurs sans échantillons sont possibles. Les buffers disposent de timestamps de présentation de sortie, mais la synchronisation avec la timebase reste à la charge du client. [C][D]

Cela pourrait permettre un traitement anticipé HLS et réduire le retard apparent de sous-titrage : **hypothèse à mesurer**, pas garantie de latence ni preuve d’accès au PCM DRM. Le nom documenté n’est pas `AVPlayerItemAudioOutput`. [C]

## 2. SpeechAnalyzer / SpeechTranscriber

### Disponibilité, langues, modèles

**Confirmé :** `SpeechAnalyzer`, `SpeechTranscriber` et `AnalyzerInput` sont disponibles à partir d’iOS 26.0. `SpeechTranscriber.isAvailable` dépend des capacités matérielles de l’appareil ; avoir iOS 26 ne garantit donc pas que ce transcripteur fonctionne. Apple recommande de désactiver la fonctionnalité ou de considérer `DictationTranscriber` si nécessaire. Aucun fallback n’est proposé implicitement dans ce MVP : un repli serait une décision de produit avec ses propres vérifications. [S][H]

Préflight prévu :

1. Vérifier `SpeechTranscriber.isAvailable`.
2. Résoudre une locale **anglaise explicite**, correspondant à la piste source et non à la langue française de l’interface, avec `supportedLocale(equivalentTo:)` / `supportedLocales`.
3. Distinguer `supportedLocales` (téléchargeables comprises) de `installedLocales`.
4. Installer les assets correspondant au transcripteur configuré, puis préparer l’analyse. [H][I][J]

`supportedLocale(equivalentTo:)` peut renvoyer une variante régionale proche, avec préférence pour un asset déjà installé ; Apple signale notamment le cas « color » / « colour ». Ne pas supposer une égalité stricte d’identifiants ni l’ensemble des variantes anglaises sur chaque appareil. [I]

**Inconnu dans cette recherche :** liste exhaustive et pérenne des modèles d’iPhone/iPad compatibles, matrice complète des variantes linguistiques, taille exacte des modèles, coût mémoire et limites thermiques. Le plan repose sur les interrogations runtime, pas sur une liste matérielle inventée ni sur le seul label « Apple Intelligence ». [H][I]

**Confirmé :** `AssetInventory` gère des modèles téléchargés depuis les serveurs Apple, conservés et mis à jour par le système, partagés entre apps. `assetInstallationRequest(supporting:)` renvoie `nil` si tout est déjà installé ; sinon appeler `downloadAndInstall()` et attendre la fin. Les réservations de locales sont limitées et peuvent entraîner une erreur ; le système peut désabonner une app d’assets peu utilisés. Les assets Speech et Translation sont deux préparations distinctes. [J]

### Format d’entrée et timeline

**Confirmé :** l’analyseur ne fait pas lui-même la conversion du format audio. Choisir un format via `bestAvailableAudioFormat(compatibleWith:)` et convertir les buffers PCM, notamment avec `AVAudioConverter` pour la base iOS 26. Ne pas imposer sans interrogation une fréquence d’échantillonnage ou un nombre de canaux supposés. [S][K]

`AnalyzerInput(buffer:bufferStartTime:)` existe sur iOS 26.0. `bufferStartTime` est un `CMTime?` : `nil` signifie continuité immédiate avec le buffer précédent, ou départ à zéro pour le premier. Les buffers **ne doivent ni se chevaucher ni revenir en arrière** dans la séquence. Apple avertit que le priming d’une conversion peut décaler les échantillons : recopier aveuglément le timestamp source sur le buffer converti peut être incorrect. [L]

**Plan :** conserver une correspondance explicite entre temps média et temps de l’analyseur, avec identifiant de génération. Un seek arrière, un remplacement d’item ou de piste doit invalider l’ancienne génération et repartir d’un nouvel analyseur, plutôt qu’injecter des temps décroissants. Un saut avant peut être représenté par un timestamp explicite sans les buffers omis ; redémarrer également lors des discontinuités importantes est un choix de simplicité à évaluer. [L][S]

**Attention aux exemples Apple actualisés en 2026 :** `AnalyzerInputConverter` et `AssetInputSequenceProvider`, désormais cités dans l’overview, sont marqués **iOS 27.0**. Ne pas les introduire comme dépendances obligatoires d’un chemin iOS 26. [V]

### Presets et stabilité du texte

Presets documentés, sans preset fictif « offlineTranscription » : [M]

| Preset | Résultats volatils | Priorité à la rapidité | Horodatage dans le texte |
|---|---|---|---|
| `.transcription` | Non | Non | Non |
| `.progressiveTranscription` | Oui | Oui | Non |
| `.timeIndexedProgressiveTranscription` | Oui | Oui | Oui |
| `.timeIndexedTranscriptionWithAlternatives` | Non | Non | Oui, avec alternatives |

`.timeIndexedProgressiveTranscription` est un candidat cohérent pour le prototype de sous-titrage, pas une preuve d’un bon compromis qualité/latence sur vidéo. `fastResults` favorise la rapidité au détriment de la précision. Les résultats volatils d’une phrase peuvent être réémis avant finalisation ; **remplacer la portion volatile, ne pas tout concaténer**. Le résultat expose une plage audio et un état de finalisation. [M][O]

**Choix MVP proposé :** traduire les segments finalisés / phrases stabilisées ; conserver les timestamps de la plage anglaise pour la cue française entière. Traduire chaque révision partielle augmenterait charge, oscillations de texte et risques de réponses périmées. Une traduction mot à mot alignée n’est pas fournie par ce simple enchaînement : la grammaire française change l’ordre des mots. Le compromis phrase longue/retard doit être mesuré.

**Confirmé :** fermer l’`AsyncStream` d’entrée ne termine généralement pas la session. Finaliser explicitement la fin normale et annuler explicitement les sorties/remplacements ; `finalizeAndFinishThroughEndOfInput()` attend la consommation puis la finalisation. [S][P]

### Permissions : audio de l’application, pas microphone

**Confirmé :** la page Apple « Asking Permission to Use Speech Recognition » précise que le mécanisme d’autorisation décrit concerne `SFSpeechRecognizer` ; les modules de transcription `SpeechAnalyzer` n’envoient pas la voix aux serveurs Apple. Ne pas ajouter par réflexe `SFSpeechRecognizer.requestAuthorization` et son usage description à un chemin exclusivement `SpeechAnalyzer`. Si un repli vers l’ancienne API est ultérieurement ajouté, ses règles s’appliquent même en mode on-device. [Q]

**Confirmé / conséquence directe :** l’autorisation microphone et `NSMicrophoneUsageDescription` concernent l’accès au microphone. Alimenter l’analyseur avec le PCM du média déjà joué ne requiert pas d’enregistrement micro. Le plan ne contient ni `AVAudioEngine.inputNode` ni boucle haut-parleur → microphone, et ne nécessite pas de convertir la session de lecture en session d’enregistrement. [A][R]

Le téléchargement de modèles reste une opération réseau de préparation, distincte de la transmission du contenu audio. « Local » ne signifie donc pas « aucun accès réseau lors de la première activation ». [J]

## 3. TranslationSession : modèle local et cycle de vie

**Confirmé :** les traductions effectuées par `TranslationSession` sont traitées sur l’appareil. Apple peut collecter des métriques d’utilisation/performance comprenant bundle ID et langues, mais pas les contenus source/traduits. Ne pas promettre une absence absolue de télémétrie système. [T]

### Deux chemins complémentaires

1. **Préparation avec UI :** `LanguageAvailability.status(from:to:)` pour la paire explicite anglais → français : `.installed`, `.supported` mais non prête, ou `.unsupported`. En cas de modèles manquants, une session fournie par `.translationTask` permet de demander le consentement de téléchargement, via `prepareTranslation()` ou traduction. `prepareTranslation()` nécessite une source connue ; ce n’est pas un import silencieux de modèle en arrière-plan. [U][W]
2. **Traitement sans UI après installation :** `TranslationSession(installedSource:target:)` est réellement disponible dès **iOS 26.0**. Il ne nécessite pas de `.translationTask`. La source est obligatoire ; choisir la cible française explicitement plutôt que `nil` et une cible dérivée des préférences. **L’initialiseur n’est pas `throws`** ; si des langues manquent, c’est l’opération de traduction qui échoue, notamment `TranslationError.notInstalled`. Cette session ne peut pas demander de téléchargement. [X][Y]

`isReady` est une vérification asynchrone, pas une réservation immuable : l’utilisateur ou le système peuvent supprimer les langues ensuite. Continuer à gérer les erreurs au moment de traduire, et permettre de repasser par l’étape de préparation. [Z]

### Piège majeur de cycle de vie SwiftUI

**Confirmé :** Apple documente un **`fatalError`** si une session fournie par `.translationTask` est utilisée après disparition de la vue attachée ou changement de configuration. Ce changement fournit une nouvelle session. Ne pas stocker cette session comme service singleton ni la faire survivre au lecteur via une tâche non structurée. Une configuration non nulle déclenche l’action à l’apparition ; les changements/invalidation relancent l’action. [AA]

**Plan iOS 26 recommandé :** une vue vivante pour préparer explicitement les modèles, puis une session directe `installedSource` détenue par le coordinateur de sous-titrage pendant sa génération active. Annuler les travaux à l’arrêt ; les résultats de traduction portent un identifiant de cue/génération pour qu’un résultat ancien n’apparaisse pas après un seek/changement de vidéo. Cette architecture est une recommandation, pas une obligation du framework. [X][AA]

**Option versionnée, non prérequis :** `TranslationSession.Strategy` est marqué **iOS 26.4**, avec `.lowLatency` (modèles traditionnels rapides) et `.highFidelity` (Apple Intelligence, meilleure fluidité). La stratégie est une préférence ; le système peut choisir une alternative selon appareil/langues. Pour un support iOS 26.0, conserver le chemin de base et ne pas employer sans garde les variantes `preferredStrategy`. Aucun chiffre de latence n’est garanti par ces noms. [AB]

## 4. Alternative native iOS 27 à étudier avant de multiplier les pipelines

Apple WWDC26 annonce des sous-titres générés localement pendant la lecture, automatiquement proposés, avec conservation de la priorité des sous-titres authored. La session distingue transcription depuis audio et traduction depuis sous-titres anglais. Elle annonce HLS live/VOD et médias fichier, dont les vidéos personnelles. **Ces annonces ne s’appliquent pas rétroactivement à iOS 26.** [N]

Pour une UI custom, `AVPlayerItem.selectableMediaSelectionOptions(in:)` est nouveau sous iOS 27 : il filtre les options capables de produire du contenu selon la sélection courante. Apple donne précisément l’exemple d’un sous-titre généré par transcription qui exige la piste audio source sélectionnée. Une option du groupe peut autrement être sélectionnée mais ne rien produire. Le mécanisme existant de sélection de sous-titres sait présenter le texte dans `AVPlayerLayer`. [AC][AD]

**Décision proposée :** sur iOS 27, vérifier d’abord si le menu natif de langues du lecteur peut répondre à EN → FR sans réimplémenter ASR/traduction. Dans cette recherche, la partie du transcript WWDC obtenue ne démontre pas la liste complète des langues/appareils, ni l’enchaînement systématique audio anglais sans sous-titres → français, ni DRM/PiP/AirPlay pour ce cas précis. Ne pas les annoncer acquis. La sortie PCM HLS iOS 27 reste une autre option si un pipeline custom est nécessaire. [C][N][AC]

## 5. Plan de réalisation proposé — uniquement après accord

### Étape 0 — verrouiller le périmètre et les critères

- MVP conseillé : anglais → français, iOS 26, vidéo fichier non protégée, vitesse 1×, premier plan ; un seul pipeline lié au lecteur existant, sans second téléchargement/décodeur et sans microphone.
- Classifier chaque source réellement fournie à `AVPlayerItem` : fichier local, fichier HTTP progressif, HLS ; ne pas se fier seulement à l’extension de l’URL.
- Préflight matériel/langue/assets ; refuser proprement source incompatible, DRM non autorisé, piste muette et modèles indisponibles, sans gêner la lecture ordinaire.
- Décider le comportement attendu pour le retard : sous-titres réactifs mais tardifs, ou décalage de lecture choisi par l’utilisateur. Une branche prenant l’audio au moment où il est joué ne peut garantir des sous-titres finals anticipés.

### Étape 1 — preuve technique bornée sur appareil physique

Après autorisation seulement : prouver réception de PCM avec timestamps depuis **l’item existant**, son intact, pas de permission micro ; couvrir local puis MP4 HTTP authentifié/progressif réel. Vérifier installation séparée Speech/Translation et une seconde exécution sans réseau pour un média local. Mesurer temps premier résultat et retard ASR → traduction, sans encore construire une infrastructure d’export.

**Critère d’arrêt :** si les sources utiles s’avèrent exclusivement HLS sur iOS 26, ne pas implémenter un tap inopérant. Revenir au choix produit : restreindre le périmètre, exploiter des sous-titres anglais existants, ou proposer une voie iOS 27 validée. Un téléchargement/décodage parallèle changerait l’exigence « audio directement du lecteur existant » et demande un nouvel accord.

### Étape 2 — pipeline et synchronisation minimaux

`item existant → tap/copie bornée → conversion PCM hors callback → AnalyzerInput horodatés → résultats EN stabilisés → file de traduction bornée → cues FR liées au temps média → affichage du lecteur`.

- Un propriétaire du cycle de vie ; annulation commune pour désactivation, disparition du lecteur, changement d’item/piste, seek incompatible et erreurs.
- Génération monotone pour rejeter les résultats périmés, sans réutiliser une session SwiftUI invalidée.
- Cue française liée à la plage anglaise entière ; ordre conservé, déduplication des partiels ; bornes mémoire et de backlog explicites.
- Ne pas remplacer sans conservation un éventuel mix audio existant ; ne pas supposer que l’overlay custom devient une piste native exportable.

### Étape 3 — décision qualité et couverture

Sur iPhone/iPad physiques représentatifs : silence, musique/bruit, plusieurs voix, accents, phrases longues, pause/reprise, seek avant/arrière, fin de lecture, changement de piste et désactivation rapide. Mesurer médiane/p95 du retard, débit, énergie, température, mémoire et frames vidéo/audio perdues. PiP, AirPlay, arrière-plan et vitesses variables restent des lots de validation distincts : pas de garantie implicite d’un overlay custom dans ces surfaces.

Pour iOS 27 : comparer la génération native et la nouvelle sortie HLS sur un média live et un VOD non protégés, puis obtenir une preuve Apple/contrat explicite pour tout élargissement DRM. Ne pas demander de contournement de protection.

## 6. Risques et inconnues qui restent ouverts

1. **Couverture des médias** : HLS iOS 26 exclu du chemin tap, MP4 distant réel à prouver ; un fichier téléchargé HLS n’équivaut pas nécessairement à un média fichier.
2. **Droits/protection** : aucune promesse de PCM DRM ; `load(.hasProtectedContent)` est un indicateur de protection, pas une autorisation d’extraction. [F]
3. **Support runtime** : iOS 26 ne suffit pas pour le matériel Speech ; langues et modèles peuvent manquer ou être supprimés. [H][J][Z]
4. **Latence et qualité** : ASR puis traduction cumulent les délais ; les timestamps précis ne rendent pas le texte disponible plus tôt. Aucune garantie chiffrée Apple trouvée pour ce montage.
5. **Discontinuités** : seek arrière et conversion avec priming peuvent casser l’alignement sans gestion explicite. [L]
6. **Cycle de vie** : session Translation issue d’une vue invalidée = risque de crash documenté, pas simple erreur récupérable. [AA]
7. **Surface de rendu** : qualité d’affichage dans PiP/AirPlay, accessibilité, concurrence avec sous-titres existants et export n’ont pas été validés.
8. **Actualité des API** : distinguer iOS 26.0, 26.4 et 27.0 malgré une documentation Apple unique mise à jour. [C][V][AB][AC]

## Sources primaires consultées

Les liens « JSON » désignent le contenu DocC complet chargé avec `web_fetch`, incluant déclarations, discussions et `metadata.platforms`. Les pages vidéo ont été récupérées directement ; l’extraction textuelle du transcript peut être tronquée, et aucun fait situé dans la partie non obtenue n’est présenté comme vérifié. Les échecs réseau TLS d’une lecture PowerShell supplémentaire n’ont produit aucune validation complémentaire.

- **[A]** Apple, `audioTapProcessor` : [documentation](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/audiotapprocessor), [JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avmutableaudiomixinputparameters/audiotapprocessor.json).
- **[B]** Apple, `AVPlayerItem.audioMix`, restriction fichier/HLS : [documentation](https://developer.apple.com/documentation/avfoundation/avplayeritem/audiomix), [JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritem/audiomix.json).
- **[C]** Apple, `AVPlayerItemSampleBufferOutput`, iOS 27, HLS/PCM/timebase : [documentation](https://developer.apple.com/documentation/avfoundation/avplayeritemsamplebufferoutput), [JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritemsamplebufferoutput.json).
- **[D]** Apple, configuration audio de cette sortie, iOS 27 : [documentation](https://developer.apple.com/documentation/avfoundation/avplayeritemsamplebufferoutputaudioconfiguration), [JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritemsamplebufferoutputaudioconfiguration.json).
- **[E]** Apple, exemple historique `MTAudioProcessingTap Audio Processor`, vidéo locale (archive de 2013, pas preuve à elle seule de compatibilité iOS 26) : [exemple](https://developer.apple.com/library/archive/samplecode/AudioTapProcessor/Introduction/Intro.html).
- **[F]** Apple, contenu protégé et chargement asynchrone : [documentation](https://developer.apple.com/documentation/avfoundation/avasset/hasprotectedcontent), [JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avasset/hasprotectedcontent.json).
- **[G]** Apple, `MTAudioProcessingTapGetSourceAudio`, durée de vie des buffers et temps asset : [documentation](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio(_:_:_:_:_:_:)), [JSON](https://developer.apple.com/tutorials/data/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio(_:_:_:_:_:_:).json).
- **[H]** Apple, `SpeechTranscriber` et `isAvailable` : [classe JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json), [isAvailable JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/isavailable.json).
- **[I]** Apple, résolution des locales : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/supportedlocale(equivalentto:).json).
- **[J]** Apple, gestion des modèles : [AssetInventory JSON](https://developer.apple.com/tutorials/data/documentation/speech/assetinventory.json), [demande d’installation JSON](https://developer.apple.com/tutorials/data/documentation/speech/assetinventory/assetinstallationrequest(supporting:).json).
- **[K]** Apple, `AnalyzerInput`, format non converti automatiquement : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/analyzerinput.json).
- **[L]** Apple, `AnalyzerInput.init(buffer:bufferStartTime:)`, monotonie et priming : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/analyzerinput/init(buffer:bufferstarttime:).json).
- **[M]** Apple, `SpeechTranscriber.Preset`, tableau des options : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/preset.json).
- **[N]** Apple, WWDC26 « Discover generated subtitles and subtitle styles », chapitres 2:14, 3:03, 4:31 : [session](https://developer.apple.com/videos/play/wwdc2026/256/).
- **[O]** Apple, `SpeechTranscriber.Result`, résultats volatils, plage et finalisation : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/result.json).
- **[P]** Apple, fin explicite de l’analyse : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput().json).
- **[Q]** Apple, autorisation Speech, note spécifique `SpeechAnalyzer` : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/asking-permission-to-use-speech-recognition.json).
- **[R]** Apple, permission microphone : [JSON](https://developer.apple.com/tutorials/data/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription.json).
- **[S]** Apple, `SpeechAnalyzer` : [JSON](https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json), [WWDC25 « Bring advanced speech-to-text to your app with SpeechAnalyzer »](https://developer.apple.com/videos/play/wwdc2025/277/).
- **[T]** Apple, `TranslationSession`, traitement local et métriques : [JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession.json).
- **[U]** Apple, disponibilité linguistique : [requête de paire JSON](https://developer.apple.com/tutorials/data/documentation/translation/languageavailability/status(from:to:).json), [états JSON](https://developer.apple.com/tutorials/data/documentation/translation/languageavailability/status.json).
- **[V]** Apple, helpers Speech **iOS 27** : [AnalyzerInputConverter JSON](https://developer.apple.com/tutorials/data/documentation/speech/analyzerinputconverter.json), [AssetInputSequenceProvider JSON](https://developer.apple.com/tutorials/data/documentation/speech/assetinputsequenceprovider.json).
- **[W]** Apple, consentement/téléchargement anticipé : [prepareTranslation JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession/preparetranslation().json).
- **[X]** Apple, initialiseur direct **iOS 26** : [JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession/init(installedsource:target:).json).
- **[Y]** Apple, distinction sessions avec/sans téléchargement : [canRequestDownloads JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession/canrequestdownloads.json).
- **[Z]** Apple, readiness et suppression ultérieure des modèles : [isReady JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession/isready.json).
- **[AA]** Apple, cycle de vie et `fatalError` de la session SwiftUI : [translationTask JSON](https://developer.apple.com/tutorials/data/documentation/swiftui/view/translationtask(_:action:).json).
- **[AB]** Apple, stratégies de traduction **iOS 26.4** : [Strategy JSON](https://developer.apple.com/tutorials/data/documentation/translation/translationsession/strategy.json).
- **[AC]** Apple, filtrage des options générées **iOS 27** : [selectableMediaSelectionOptions JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/avplayeritem/selectablemediaselectionoptions(in:).json).
- **[AD]** Apple, sélection de sous-titres et rendu `AVPlayerLayer` : [article JSON](https://developer.apple.com/tutorials/data/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks.json).
