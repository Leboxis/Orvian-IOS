# Orvian

Application iOS native pour parcourir, organiser et consulter vos fichiers, en Swift + SwiftUI.
Pensé pour une expérience « Apple Photos » : grilles de miniatures fluides,
visionneuse photos avec zoom, lecteur vidéo AVPlayer quasi instantané.


## Démarrage

### 1. Token API

L'app se configure avec un **token API** :

1. Connectez-vous au portail de gestion de votre service de fichiers.
2. Ouvrez Profil → Développeur → **Tokens API**.
3. Créez un token autorisant l’accès à vos fichiers ; les opérations d’import et de modification nécessitent les droits correspondants.
4. Au premier lancement d'Orvian, collez ce token — il est stocké dans le Keychain
   (repli automatique sur UserDefaults si le Keychain est indisponible, ex. LiveContainer)

Les comptes et drives accessibles sont découverts automatiquement
(`GET /1/account` puis `GET /2/drive?account_id=…`).

### 2. Build & installation via LiveContainer

Le dépôt ne contient **pas** de `.xcodeproj` : il est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen)
à partir de `project.yml`, aussi bien en local que dans la CI.

**Via GitHub Actions (recommandé)** :

1. Poussez ce dépôt sur GitHub
2. Chaque push sur `main` produit un artefact **IPA non signé** (onglet Actions du repo)
3. Chaque push sur `main` crée aussi automatiquement la prochaine version, sa **Release** et met à jour la source LiveContainer. Numérotation : patch +1 à chaque push (`0.9.3` → `0.9.4`), minor +1 tous les 10 pushes (`0.9.9` → `0.10.0`). Série actuelle : `0.9.x`.
4. Téléchargez l'IPA sur l'iPhone → partagez-le vers **LiveContainer** → importez

**En local (macOS)** :

```bash
brew install xcodegen
xcodegen generate
open Orvian.xcodeproj   # puis Cmd+R avec son certificat de développement
```

### 3. Installation directe via la source LiveContainer

LiveContainer sait lire les sources de type AltStore (`repo.json`) : à chaque
push sur `main`, la CI publie la prochaine version et met automatiquement le JSON à jour.

1. Dans LiveContainer : onglet **Sources → Add Source**
2. Collez : `https://raw.githubusercontent.com/Leboxis/Orvian-IOS/refs/heads/main/repo.json`
3. Appuyez sur **Install** sur l'app Orvian — pas de téléchargement IPA manuel

Lien direct (si votre version de LiveContainer le supporte) :
`livecontainer://source?url=https%3A%2F%2Fraw.githubusercontent.com%2FLeboxis%2FOrvian-IOS%2Frefs%2Fheads%2Fmain%2Frepo.json`

### 4. CI

`.github/workflows/build.yml` (runner `macos-26`) :

```
checkout → xcodegen → xcodebuild (unsigned, generic/platform=iOS)
        → packaging Payload/Orvian.app en IPA → artefact → Release si tag
```

Ce workflow sert aussi de **vérification de compilation** : le code est développé
hors Mac, la CI valide chaque push.

## Architecture

### Scan SFW / NSFW du dossier ouvert

Dans un dossier, le bouton **Scanner ce dossier** (icône de viseur dans la barre
supérieure) analyse ses images directement contenues, sur toutes ses pages.
La feuille indique la progression, les résultats SFW / NSFW et les erreurs ;
elle permet d'annuler le scan et de régler le seuil NSFW (80 % par défaut).
Les résultats se retrouvent dans **Filtres → Classification des images** :
Tous, SFW, NSFW ou À analyser. Le seuil reclasse les scores sans nouvelle analyse.

Core ML / Vision réalise la classification sur l'appareil avec le modèle
Marqo ViT-Tiny embarqué (~11 Mo). Les miniatures à analyser sont récupérées
depuis votre espace de fichiers ; aucune image ou classification n'est envoyée à un service d'IA.
Les scores restent locaux, isolés par compte / drive, et sont réanalysés après
une modification du fichier. La navigation conserve le scan au premier plan ;
passer l'app en arrière-plan l'interrompt en gardant les résultats obtenus.

Le scan concerne le dossier ouvert uniquement. Les sous-dossiers et les vidéos
ne sont pas parcourus ; un GIF est classé à partir d'une miniature fixe.
Le classement dépend des miniatures, du modèle et du seuil, et peut se tromper.
Une erreur reste Non analysée. Préparation reproductible du modèle :
`scripts/nsfw/convert_model.py` ; vérifications : `scripts/nsfw/verify_model.py`.
Les attributions figurent dans `Orvian/Resources/NSFW-MODEL-NOTICE.md`.

```
View (SwiftUI) → ViewModel (@MainActor @Observable) → Repository
                                                        → APIClient (actor, URLSession)
                                                        → API de fichiers v2/v3
```

```
Orvian/
├── App/            OrvianApp, RootView, MainTabView (5 onglets vivants en ZStack)
├── Core/
│   ├── API/        APIClient (actor), Endpoints, Repository, APIError
│   ├── Auth/       TokenStore (Keychain + repli), SessionStore (session @Observable)
│   ├── Cache/      ThumbnailProvider (mémoire→disque→réseau), DiskImageCache (LRU)
│   ├── Media/      MediaURLCache (URLs temporaires), HiresImageStore (ImageIO)
│   └── Utils/      ByteFormatter, FileKind (icône + teinte par type)
├── Models/         Drive, DriveFile (FileV3/DirectoryV3), CursorPage
├── Features/       Onboarding, Home, Files, Favorites, Media, More, Viewer, Shared
└── UI/             DesignSystem, FloatingTabBar
```

Points clés :

- **Aucun appel réseau ni décodage d'image sur le MainActor** ; les vues-modèles sont
  `@MainActor`, tout le reste vit dans des actors (`APIClient`, `ThumbnailProvider`,
  `MediaURLCache`, `HiresImageStore`).
- **Pagination curseur** de l'API v3 (`cursor` / `has_more`) gérée par `FileGridViewModel`.
- Les couleurs par type de fichier sont **discrètes** : icône teintée, fond à 10 %
  d'opacité, bordure légère — la miniature domine toujours.

## Sécurité

- `.env.local` (token, IDs) est **exclu du dépôt** via `.gitignore` — aucun secret n'est commité.
- Le token est envoyé uniquement aux hôtes HTTPS autorisés de l’API et des
  sessions d’upload de votre service de fichiers. Toute autre destination,
  y compris après redirection, est refusée.
- La spécification OpenAPI officielle (licence MIT) est conservée dans le dépôt comme référence.

## Compatibilité

- iOS 26.0+, iPhone & iPad
- Conçu pour **LiveContainer** : aucun entitlement exotique, pas de BGTaskScheduler,
  Keychain avec repli UserDefaults, IPA non signé produit par la CI.
