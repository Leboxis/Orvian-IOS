# Prototype audio → SpeechAnalyzer : exécution et décision

20 octobre 2026. **Faisabilité kDrive démontrée sur appareil (IPA `7b7d5453`), puis MVP promu en code de production.**

Le MVP est livré en production (non gated) : bouton « CC / Traduction », modes anglais / français (traduction automatique), overlay de sous-titres et reprise automatique après seek/scrub. Le [panneau de diagnostic](../../Orvian/Features/Viewer/VideoSpeechProbe.swift) reste `#if DEBUG` uniquement.

## Ce qui a été ajouté (production, non gated)

- [Tap pass-through](../../Orvian/Core/Media/PlayerSpeechAudioTap.swift) sur le même AVPlayerItem, sans second lecteur, microphone, décodeur parallèle ou téléchargement intégral.
- [Mailbox bornée](../../Orvian/Core/Media/SpeechProbeMailbox.swift) : 16 réserves de 256 Kio (4 Mio de données préallouées). Copie dans le callback ; aucun appel modèle, Task, conversion ou réseau à cet endroit. Un verrou essayé sans attente protège les échanges ; contention/saturation provoque un arrêt explicite du test, pas une attente dans le son. Ce compromis de prototype n’est pas une garantie hard-real-time.
- [Worker acteur](../../Orvian/Core/Media/SpeechProbeWorker.swift) : conversion PCM sur un contexte hors UI, entrée Speech bornée à 64 buffers, cumul entier des frames de sortie et finalisation/annulation explicites.
- [Timeline de sous-titres](../../Orvian/Core/Media/SubtitleCue.swift) (`SubtitleMode`, `SubtitleCue`, `SubtitleCueTimeline`) : fusion provisoire/définitif, remplacement anglais→français au même instant, éviction périmée bornée.
- [Traducteur acteur](../../Orvian/Core/Media/SubtitleTranslator.swift) : session `TranslationSession(installedSource:target:)` directe, préparation puis traduction à la volée, réinitialisation après deux échecs.
- [Overlay et menu CC](../../Orvian/UI/SubtitleOverlay.swift) : `SubtitleOverlay` non interactif et `SubtitleModeMenu` (coches), insérés dans les contrôles du lecteur sans toucher aux choix d’interface protégés.
- [Pilote du lecteur](../../Orvian/Features/Viewer/VideoSpeechProbe.swift) : `setMode` pilote le `.translationTask` (seul déclencheur de l’UI de consentement de téléchargement du modèle français), `refresh` ne republie que les cues modifiés (évite un re-rendu 4 Hz), `scheduleRestartIfIdle` relance la capture après seek/scrub/retour à 1× (récupération bornée).
- Raccordement production via `SubtitleModeMenu` (transport iPhone + barre du bas) et `.translationTask` dans [VideoPlayerView](../../Orvian/Features/Viewer/VideoPlayerView.swift).

Les modèles sont préparés avant l’installation du tap pour éviter de remplir sa file pendant le démarrage de Speech. Le téléchargement du modèle anglais requiert un second clic explicite si le modèle manque. Aucun texte/URL signé/jeton n’est journalisé ou écrit sur disque par le prototype. Seul le dernier segment (500 caractères maximum) est conservé dans l’interface ; ce n’est pas un export de transcription.

## Limites assumées

- iOS 26+, appareil compatible SpeechTranscriber et locale anglaise disponibles à l’exécution.
- Premier plan, lecture locale sur l’appareil à **1×**, une seule piste audio, PCM mono/stéréo. Un média distant progressif n’est pas un « serveur de transcription » : seul le téléchargement vidéo utilise le réseau kDrive.
- Source protégée ou non composable refusée. `isComposable` est une barrière conservatrice, pas un classificateur parfait de tous les conteneurs ; une source refusée n’est pas une preuve que toute autre architecture serait impossible.
- HLS/DRM, compositions complexes et AirPlay/PiP hors périmètre : la capture exige une source locale 1× non protégée, mono-piste. Ces cas basculent le mode en `off` avec un message explicite.
- Seek, scrub, vitesse modifiée, app inactive, lecteur remplacé ou fermé : arrêt et effacement du texte, puis relance automatique bornée (jusqu’à 3 tentatives) après retour à 1× local. Une discontinuité transitoire (D1–D3, saturation, audio source) relance sans couper le mode ; une erreur fatale (DRM, modèle, format) le coupe. Pause/reprise à la même position garde la session.
- Conversion avec primeMethod `.none`, sans pré-roll : correspondance des temps à mesurer sur appareil avant de promettre une synchronisation précise.
- Résultats provisoires remplacés à l’écran, pas concaténés. Le résultat « définitif » n’est pas à lui seul une preuve que toutes les paroles ont été correctement reconnues.
- Le tap peut ne produire aucun PCM, notamment selon les conditions de lecture muette ou de source ; ce comportement fait partie des observations à consigner.

## 0. Rapport d’échec du 20 octobre 2026 et correctif

Premier essai sur appareil avec l’IPA de diagnostic `41047dc6` : après « Tester l’audio anglais », l’écran affiche « Tap installé » avec **PCM 0 bloc / 0,0 s**, la vidéo s’arrête, puis « Discontinuité audio » apparaît dès la reprise de lecture.

**Cause reproduite en test local :** le premier bloc PCM réel était rejeté avant d’être compté. Le contrôle temporel exigeait une position média exploitable pour le tout premier paquet ; un horodatage source absent ou invalide était traité comme une discontinuité. Le compteur PCM restait donc à zéro alors que l’audio pouvait déjà circuler. L’ancien code ne pouvait d’ailleurs jamais transcrire un flux dont la position initiale manquait, même avec un audio parfaitement valide.

**Correctifs appliqués :**

- Le PCM reste exploitable sans position média : l’horloge est marquée incomplète, le retard n’est plus affiché plutôt qu’inventé, et une position réelle ultérieure ré-ancre le suivi.
- Les trois causes de discontinuité sont désormais distinctes et numérotées (D1 redémarrage de flux, D2 saut temporel arrière, D3 changement de format) au lieu d’un message unique.
- Le panneau sépare **audio reçu** (blocs et secondes) et **blocs analysés**, et affiche les compteurs internes du tap : callbacks, préparations, `OSStatus`, frames, flags.
- La durée d’un paquet est calculée à partir des frames réellement reçues, plus fiable qu’une plage média parfois incomplète.
- Le prototype n’impose jamais la lecture : après l’installation du tap, il réaffirme l’intention courante via le chemin de reprise du lecteur, et ne contredit jamais une pause demandée. Un test sans audio et sans lecture active s’arrête avec un message explicite au lieu d’attendre indéfiniment.

Ces changements restent un diagnostic : ils ne prouvent pas encore que la source kDrive fournit le PCM attendu. Le prochain essai doit indiquer si **audio reçu** augmente, même si l’analyse échoue ensuite.

### Deuxième essai (IPA `7b7d5453`) : ce qui a été durci avant livraison

Le premier rapport prouvait déjà l’extraction PCM kDrive (`frames=4096`, `44100 Hz`, position 17,15 s, lecture à 1×) et un bloc analysé. L’absence de texte venait de l’arrêt du test, pas du tap. Trois causes d’arrêt prématuré ont été supprimées :

- **État `.inactive` transitoire** (notification, centre de contrôle) : seul l’arrière-plan arrête désormais le test.
- **File Speech trop courte** (8 buffers, ~0,7 s) : elle débordait pendant le démarrage du modèle. Elle accepte maintenant 64 buffers (~12 s).
- **Rejet `.dropped` traité comme fatal** : un pic de charge arrêtait tout. Le yield réessaie maintenant jusqu’à 2 s, puis échoue explicitement.

Le panneau distingue désormais quatre niveaux : **audio reçu**, **analysés**, **résultats Speech** et **résultats avec texte**. Cette séparation est ce qui rend le prochain essai décisif :

| Observation | Interprétation |
|---|---|
| `analysés` augmente, `résultats` reste 0 | Speech ne produit rien : format d’entrée ou session en cause. |
| `résultats` augmente, `avec texte` reste 0 | Speech tourne mais n’entend pas de parole exploitable. |
| `avec texte` augmente, pas de texte affiché | Défaut d’affichage, pas de transcription. |

Un défaut de finalisation a aussi été corrigé : `isFinished` était marqué avant la finalisation de l’analyseur, ce qui pouvait laisser une session ouverte si la finalisation échouait.


## 1. Ouvrir le prototype sur l’appareil

### Sans Mac : IPA « Orvian Test IA » pour LiveContainer

1. Télécharger l’IPA **Orvian-Test-IA-…-unsigned.ipa** joint à la préversion de diagnostic GitHub, et l’importer comme **nouvelle application** dans LiveContainer. Ne pas l’utiliser pour remplacer Orvian normal.
2. Ouvrir **Orvian Test IA**, se connecter à kDrive si demandé, puis ouvrir une vidéo anglaise à **1×**, sans AirPlay.
3. Déplier **Test audio IA (développement)** : il est visible directement, sans variable d’environnement ni argument.
4. Toucher **Tester l’audio anglais**, puis **Télécharger le modèle anglais et tester** si le modèle manque. Aucun téléchargement de modèle n’est lancé simplement en ouvrant l’app.
5. Relever le message, **Audio reçu** (blocs et secondes), **analysés**, la ligne **Tap** et le texte anglais. Si le test échoue, transmettre ces lignes, sans URL signée ni jeton.

L’IPA porte l’identifiant distinct `com.orvian.app.speechprobe`. Il est construit en Release optimisée avec le seul flag `ORVIAN_SPEECH_PROBE`, pas avec tous les comportements Debug. Le job dédié est déclenché manuellement depuis une branche `diagnostics/speech-probe…` et ne lance ni simulateur, ni vérification visuelle, ni capture. Sa publication est une **préversion non latest**, liée au commit de cette branche ; elle ne modifie ni le catalogue LiveContainer stable ni la numérotation normale.

La traduction française est incluse en production (MVP). La compatibilité Speech et le fonctionnement à l’intérieur de LiveContainer restent à vérifier sur ton appareil : la compilation seule ne prouve pas l’accès au PCM kDrive ni la disponibilité du modèle français.

### Avec Mac : exécution Debug depuis Xcode

1. Sur Mac, générer le projet avec XcodeGen à partir de [la configuration existante](../../project.yml) et utiliser un SDK iOS 26 ou supérieur.
2. Configurer la signature locale si nécessaire, sélectionner le schéma Orvian et un iPhone/iPad physique compatible, configuration **Debug**.
3. Dans **Edit Scheme → Run → Arguments**, ajouter l’argument `-OrvianSpeechProbe`, ou la variable d’environnement `ORVIAN_SPEECH_PROBE=1`.
4. Lancer l’application. Ouvrir une vidéo kDrive anglaise et rester à 1×, sans AirPlay.
5. Déplier « Test audio IA (développement) », puis toucher « Tester l’audio anglais ».
6. Si le modèle manque, le test s’arrête avant de capturer l’audio. Toucher « Télécharger le modèle anglais et tester » pour autoriser sa préparation, puis attendre. La lecture vidéo n’est pas mise en pause par le test.
7. Observer les compteurs PCM, le dernier texte anglais et l’état. Comparer à une phrase connue réellement prononcée dans la vidéo.

Sans argument/variable, un build Debug ordinaire n’affiche pas le panneau de diagnostic. Le **MVP de sous-titres** est en revanche livré en production (non gated) : l’IPA Release normale propose le bouton « CC / Traduction ». Seul le **panneau de diagnostic** reste `#if DEBUG` et n’apparaît que dans l’IPA dédiée (`ORVIAN_SPEECH_PROBE`) ou avec l’argument `-OrvianSpeechProbe`.

## 2. Contrôle local puis vraie source kDrive

Le [harness iOS non visuel](../../Tests/iOS/SpeechProbeTests.swift) contient un test manuel optionnel :

1. Fournir une courte vidéo de référence anglaise non protégée nommée `speech-probe-en.mp4` parmi les ressources du bundle de tests iOS. Le fichier n’est pas fourni ici ; vérifier l’inclusion de la ressource après régénération du projet.
2. Installer le modèle anglais via le panneau de l’application sur le même appareil.
3. Pour l’action **Test** du schéma, définir `ORVIAN_RUN_SPEECH_PROBE=1` dans l’environnement du processus de test, puis exécuter seulement `SpeechProbeTests/testManualLocalEnglishFixtureProducesPCMAndTranscript` sur l’appareil. Le test est ignoré par défaut, ainsi que si la fixture ou les modèles sont absents ; il ne télécharge pas de modèle et n’effectue pas de capture d’écran.
4. Une transcription non vide vérifie le câblage ; l’exactitude par rapport à la phrase connue reste à contrôler. Ce contrôle local ne valide pas l’extraction kDrive.
5. Avec le panneau, tester ensuite au moins trois véritables vidéos kDrive : référence courte, vidéo représentative et vidéo longue. Ne pas copier d’URL signée ou de transcription privée dans un rapport public.

## 3. Matrice de vérification manuelle

| Scénario | Résultat attendu / preuve à relever |
|---|---|
| Test désactivé / build Release | Lecture inchangée, pas de modèle préparé ni de tap installé par ce code. |
| Local de référence puis kDrive | Compteurs PCM croissants et transcription reconnaissable ; son original intact. |
| Modèle absent, réseau absent/refus d’installer | Message explicite, vidéo toujours lisible ; aucun repli serveur. |
| Pause puis reprise sans déplacement | Pas d’avancement PCM continu en pause ; reprise ou arrêt explicite si discontinuité. |
| Seek avant/arrière, scrub, retour à zéro | Test arrêté, ancien texte effacé ; relance manuelle à la position réellement atteinte. |
| Vitesse 0,5×/2× | Vidéo toujours fonctionnelle, test arrêté/refusé tant qu’elle n’est pas à 1×. |
| Mute, écouteurs, contrôle masqué | Consigner si PCM/transcription persistent ; contrôles et audio normaux. |
| Source incompatible, multi-audio, mix préexistant | Refus explicite du prototype, sans remplacement du mix ni blocage de la lecture. |
| Aucun PCM après environ huit secondes de lecture | Diagnostic « extraction non prouvée », pas de faux succès. |
| « Audio reçu » augmente mais « analysés » reste à 0 | Distinguer un rejet aval (format, conversion) d’un problème de tap ; la ligne Tap fournit callbacks/OSStatus/frames. |
| Vidéo suspendue après installation du tap | Le test réaffirme l’intention de lecture via le lecteur ; une pause explicite reste prioritaire. |
| Activations/arrêts rapides, changement de page/fichier/compte | Pas de résultat tardif de l’ancienne génération ; pas de sessions simultanées. |
| App inactive/arrière-plan, fermeture, récupération réseau | Branche fermée, texte effacé, pas de reprise automatique du test. |
| Lecture 15 minutes | Files/mémoire bornées, pas de dérive continue, pas de coupure son imputable au test ; relever CPU/thermique avec Instruments. |

Le « retard média » affiché est **position AVPlayer à l’arrivée du résultat moins fin de sa plage audio**. Ce n’est ni la latence murale totale, ni une mesure de traduction, ni une garantie d’alignement mot à mot. Il peut être négatif si AVFoundation fournit de l’audio en avance.

## 4. Décision et promotion en MVP

**GO obtenu sur appareil** (IPA `7b7d5453`) : PCM kDrive extrait, paroles anglaises reconnues et affichées dans le panneau de test, lecture intacte, arrêt/libération corrects. Réussite locale + compteur PCM + transcription = **GO kDrive validé**.

Le MVP a ensuite été promu en code de production (non gated) : modes anglais/français, overlay de sous-titres, bouton « CC / Traduction » et reprise automatique après seek/scrub. Le panneau de diagnostic reste `#if DEBUG`. Les lots de stabilisation et l’évaluation de la voie système iOS 27 restent distincts.

**NO-GO de cette voie** si le fichier distant utile ne produit pas de PCM exploitable. Distinguer une absence d’accès source d’un problème de concurrence/format du prototype. Ne pas ajouter automatiquement un second téléchargement, serveur, FFmpeg ou remplacement du lecteur. Présenter les observations avant de choisir une autre architecture.

Voir le [plan approuvé](../superpowers/plans/2026-10-20-realtime-translated-subtitles.md) pour le suivi des lots MVP.

## Vérifications effectuées dans cet environnement

- Analyse syntaxique Swift Debug et Release réussie (ce n’est pas un typecheck des frameworks Apple).
- 110 tests Python non visuels (dont les contrôles de livraison MVP et de la timeline de sous-titres) et contrôle existant des régressions de performance réussis.
- [Tests comportementaux de la mailbox/timeline](../../Tests/SpeechProbeChecks.swift) compilés et exécutés avec succès sur le vrai code de production (Swift 6.4, mode Swift 5, DEBUG), via [le script portable](../../.github/scripts/check_speech_probe.py). Le bac à sable Windows bloquait l’écriture de l’exécutable temporaire ; la même commande a réussi avec l’autorisation ponctuelle demandée, sans modification des permissions Windows.
- Tests Apple spécifiques fournis mais non exécutés sous Windows. Aucun build/typecheck SDK Apple, aucune vidéo locale ou kDrive réellement analysée et aucune mesure de performance sur appareil. Aucun workflow/capture visuel GitHub Actions déclenché.
