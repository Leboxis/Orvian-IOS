# Prototype audio → SpeechAnalyzer : exécution et décision

20 octobre 2026. **Prototype préparé, faisabilité kDrive NON encore démontrée.**

Ce lot ne traduit pas en français et ne constitue pas le bouton « CC / Traduction » du MVP. Il teste une seule question : le lecteur actuel fournit-il du PCM exploitable par SpeechAnalyzer, sans interrompre la vidéo ?

## Ce qui a été ajouté

- [Tap pass-through](../../Orvian/Core/Media/PlayerSpeechAudioTap.swift) sur le même AVPlayerItem, sans second lecteur, microphone, décodeur parallèle ou téléchargement intégral.
- [Mailbox bornée](../../Orvian/Core/Media/SpeechProbeMailbox.swift) : 16 réserves de 256 Kio (4 Mio de données préallouées). Copie dans le callback ; aucun appel modèle, Task, conversion ou réseau à cet endroit. Un verrou essayé sans attente protège les échanges ; contention/saturation provoque un arrêt explicite du test, pas une attente dans le son. Ce compromis de prototype n’est pas une garantie hard-real-time.
- [Worker acteur](../../Orvian/Core/Media/SpeechProbeWorker.swift) : conversion PCM sur un contexte hors UI, entrée Speech bornée à huit buffers, cumul entier des frames de sortie et finalisation/annulation explicites.
- [Panneau de diagnostic](../../Orvian/Features/Viewer/VideoSpeechProbe.swift), raccordé au [lecteur actuel](../../Orvian/Features/Viewer/VideoPlayerView.swift) en Debug avec activation de lancement, ou directement dans l’IPA de diagnostic compilé avec `ORVIAN_SPEECH_PROBE`.

Les modèles sont préparés avant l’installation du tap pour éviter de remplir sa file pendant le démarrage de Speech. Le téléchargement du modèle anglais requiert un second clic explicite si le modèle manque. Aucun texte/URL signé/jeton n’est journalisé ou écrit sur disque par le prototype. Seul le dernier segment (500 caractères maximum) est conservé dans l’interface ; ce n’est pas un export de transcription.

## Limites assumées

- iOS 26+, appareil compatible SpeechTranscriber et locale anglaise disponibles à l’exécution.
- Premier plan, lecture locale sur l’appareil à **1×**, une seule piste audio, PCM mono/stéréo. Un média distant progressif n’est pas un « serveur de transcription » : seul le téléchargement vidéo utilise le réseau kDrive.
- Source protégée ou non composable refusée. `isComposable` est une barrière conservatrice, pas un classificateur parfait de tous les conteneurs ; une source refusée n’est pas une preuve que toute autre architecture serait impossible.
- HLS/DRM, compositions complexes, AirPlay/PiP, traduction et affichage de sous-titres synchronisés de production hors lot.
- Seek, scrub, vitesse modifiée, app inactive, lecteur remplacé ou fermé : arrêt et effacement du texte, puis relance manuelle du test. Pause/reprise à la même position garde la session ; une discontinuité détectée l’arrête proprement.
- Conversion avec primeMethod `.none`, sans pré-roll : correspondance des temps à mesurer sur appareil avant de promettre une synchronisation précise.
- Résultats provisoires remplacés à l’écran, pas concaténés. Le résultat « définitif » n’est pas à lui seul une preuve que toutes les paroles ont été correctement reconnues.
- Le tap peut ne produire aucun PCM, notamment selon les conditions de lecture muette ou de source ; ce comportement fait partie des observations à consigner.

## 1. Ouvrir le prototype sur l’appareil

### Sans Mac : IPA « Orvian Test IA » pour LiveContainer

1. Télécharger l’IPA **Orvian-Test-IA-…-unsigned.ipa** joint à la préversion de diagnostic GitHub, et l’importer comme **nouvelle application** dans LiveContainer. Ne pas l’utiliser pour remplacer Orvian normal.
2. Ouvrir **Orvian Test IA**, se connecter à kDrive si demandé, puis ouvrir une vidéo anglaise à **1×**, sans AirPlay.
3. Déplier **Test audio IA (développement)** : il est visible directement, sans variable d’environnement ni argument.
4. Toucher **Tester l’audio anglais**, puis **Télécharger le modèle anglais et tester** si le modèle manque. Aucun téléchargement de modèle n’est lancé simplement en ouvrant l’app.
5. Relever le message, le compteur PCM et le texte anglais après quelques secondes de paroles. Si le test échoue, transmettre le message et les compteurs, sans URL signée ni jeton.

L’IPA porte l’identifiant distinct `com.orvian.app.speechprobe`. Il est construit en Release optimisée avec le seul flag `ORVIAN_SPEECH_PROBE`, pas avec tous les comportements Debug. Le job dédié est déclenché manuellement depuis une branche `diagnostics/speech-probe…` et ne lance ni simulateur, ni vérification visuelle, ni capture. Sa publication est une **préversion non latest**, liée au commit de cette branche ; elle ne modifie ni le catalogue LiveContainer stable ni la numérotation normale.

La traduction française n’est pas encore incluse. La compatibilité Speech et le fonctionnement à l’intérieur de LiveContainer restent à vérifier sur ton appareil : la compilation seule ne prouve pas l’accès au PCM kDrive.

### Avec Mac : exécution Debug depuis Xcode

1. Sur Mac, générer le projet avec XcodeGen à partir de [la configuration existante](../../project.yml) et utiliser un SDK iOS 26 ou supérieur.
2. Configurer la signature locale si nécessaire, sélectionner le schéma Orvian et un iPhone/iPad physique compatible, configuration **Debug**.
3. Dans **Edit Scheme → Run → Arguments**, ajouter l’argument `-OrvianSpeechProbe`, ou la variable d’environnement `ORVIAN_SPEECH_PROBE=1`.
4. Lancer l’application. Ouvrir une vidéo kDrive anglaise et rester à 1×, sans AirPlay.
5. Déplier « Test audio IA (développement) », puis toucher « Tester l’audio anglais ».
6. Si le modèle manque, le test s’arrête avant de capturer l’audio. Toucher « Télécharger le modèle anglais et tester » pour autoriser sa préparation, puis attendre. La lecture vidéo n’est pas mise en pause par le test.
7. Observer les compteurs PCM, le dernier texte anglais et l’état. Comparer à une phrase connue réellement prononcée dans la vidéo.

Sans argument/variable, un build Debug ordinaire n’affiche pas le panneau. En Release normale sans flag dédié, le code du prototype est exclu par `#if DEBUG || ORVIAN_SPEECH_PROBE` : **l’IPA Release habituel ne permet pas de réaliser ce test**. Seul le job de diagnostic active le flag ; la publication normale reste inchangée.

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
| Activations/arrêts rapides, changement de page/fichier/compte | Pas de résultat tardif de l’ancienne génération ; pas de sessions simultanées. |
| App inactive/arrière-plan, fermeture, récupération réseau | Branche fermée, texte effacé, pas de reprise automatique du test. |
| Lecture 15 minutes | Files/mémoire bornées, pas de dérive continue, pas de coupure son imputable au test ; relever CPU/thermique avec Instruments. |

Le « retard média » affiché est **position AVPlayer à l’arrivée du résultat moins fin de sa plage audio**. Ce n’est ni la latence murale totale, ni une mesure de traduction, ni une garantie d’alignement mot à mot. Il peut être négatif si AVFoundation fournit de l’audio en avance.

## 4. Décision obligatoire avant le MVP

**GO** seulement après preuve appareil du cas kDrive réel : PCM + paroles anglaises correctes, lecture intacte, arrêt/libération corrects, mesures acceptables et absence d’accumulation sur 15 minutes. Réussite locale seule, compteur PCM seul ou tests de mailbox seuls = **pas de GO kDrive**.

**NO-GO de cette voie** si le fichier distant utile ne produit pas de PCM exploitable. Distinguer une absence d’accès source d’un problème de concurrence/format du prototype. Ne pas ajouter automatiquement un second téléchargement, serveur, FFmpeg ou remplacement du lecteur. Présenter les observations avant de choisir une autre architecture.

Après GO seulement : passer aux lots de stabilisation, traduction française, timeline et bouton CC du [plan approuvé](../superpowers/plans/2026-10-20-realtime-translated-subtitles.md). La voie système iOS 27 reste une évaluation distincte, non implémentée ici.

## Vérifications effectuées dans cet environnement

- Analyse syntaxique Swift Debug et Release réussie (ce n’est pas un typecheck des frameworks Apple).
- 97 tests Python non visuels et contrôle existant des régressions de performance réussis.
- [Tests comportementaux de la mailbox/timeline](../../Tests/SpeechProbeChecks.swift) compilés et exécutés avec succès sur le vrai code de production (Swift 6.4, mode Swift 5, DEBUG), via [le script portable](../../.github/scripts/check_speech_probe.py). Le bac à sable Windows bloquait l’écriture de l’exécutable temporaire ; la même commande a réussi avec l’autorisation ponctuelle demandée, sans modification des permissions Windows.
- Tests Apple spécifiques fournis mais non exécutés sous Windows. Aucun build/typecheck SDK Apple, aucune vidéo locale ou kDrive réellement analysée et aucune mesure de performance sur appareil. Aucun workflow/capture visuel GitHub Actions déclenché.
