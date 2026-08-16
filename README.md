# Orvian

Client iOS natif non officiel pour **kDrive** (Infomaniak), en Swift + SwiftUI.
Pensé pour une expérience « Apple Photos » : grilles de miniatures fluides,
visionneuse photos avec zoom, lecteur vidéo AVPlayer quasi instantané.

## Fonctionnalités (jalon 4 — v0.4.0)

- **5 onglets** avec barre flottante translucide, de gauche à droite :
  **Réglages · Tag · Accueil · Favoris · Profil**
- **Accueil** : navigation dans l'arborescence du drive, dossiers en premier,
  breadcrumb compact, pagination infinie, pull-to-refresh — l'ancien contenu
  reste affiché pendant le rechargement
- **Tag** : catégories kDrive (couleur, nom) et grille des fichiers de chaque
  catégorie, avec navigation dans les dossiers
- **Favoris** : grille des favoris, bascule de l'étoile optimiste depuis les
  cartes, navigation dans les dossiers favoris
- **Réglages** : stockage du drive, purge du cache de miniatures, changement de drive
- **Profil** : compte Infomaniak, drive utilisé, version, déconnexion
- **Cartes uniformes** : zone de miniature carrée stricte — toutes les cartes
  ont exactement la même taille, quelle que soit l'orientation d'origine
- **Visionneuse photos** : pager plein écran, pinch zoom, double-tap, fermeture au swipe vertical,
  miniature instantanée puis haute résolution sous-échantillonnée (ImageIO)
- **Lecteur vidéo** : lecteur système AVKit (VideoPlayer) via URL temporaire
  (pré-résolue en amont pour démarrer vite) — contrôles natifs, PiP, AirPlay, vitesse
- **Ajout** : bouton « + » dans les dossiers — créer un dossier, importer un
  fichier, importer photos/vidéos (upload kDrive v3, conflits renommés automatiquement)
- **Couleurs de dossiers** : teinte d'origine définie dans kDrive (API), sinon
  teinte par type ; l'onglet Accueil démarre sur le 2e dossier de la racine
- **Performance** : cache mémoire + disque LRU (250 Mo) des miniatures, déduplication des requêtes,
  annulation hors écran, préchargement des cartes suivantes, décodage hors thread principal

### Non inclus dans ce jalon (route map)

Recherche, corbeille, téléchargement manuel, cache offline, liens de partage,
commentaires, catégories, actions sur fichiers (déplacer/renommer), synchronisation.

## Démarrage

### 1. Token API

L'app se configure avec un **token API Infomaniak** :

1. Connectez-vous sur [manager.infomaniak.com](https://manager.infomaniak.com)
2. Profil → Développeur → **Tokens API** (ou via [developer.infomaniak.com](https://developer.infomaniak.com))
3. Créez un token pour le produit **kDrive** avec les droits de lecture
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
3. Un tag (`git tag v0.1.0 && git push --tags`) crée une **Release** avec l'IPA
4. Téléchargez l'IPA sur l'iPhone → partagez-le vers **LiveContainer** → importez

**En local (macOS)** :

```bash
brew install xcodegen
xcodegen generate
open Orvian.xcodeproj   # puis Cmd+R avec son certificat de développement
```

### 3. CI

`.github/workflows/build.yml` (runner `macos-26`) :

```
checkout → xcodegen → xcodebuild (unsigned, generic/platform=iOS)
        → packaging Payload/Orvian.app en IPA → artefact → Release si tag
```

Ce workflow sert aussi de **vérification de compilation** : le code est développé
hors Mac, la CI valide chaque push.

## Architecture

```
View (SwiftUI) → ViewModel (@MainActor @Observable) → KDriveService (Repository)
                                                        → APIClient (actor, URLSession)
                                                        → kDrive API v2/v3
```

```
Orvian/
├── App/            OrvianApp, RootView, MainTabView (5 onglets vivants en ZStack)
├── Core/
│   ├── API/        APIClient (actor), Endpoints, KDriveService, APIError
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
- Le token ne quitte l'app que vers `api.infomaniak.com` (en-tête `Authorization: Bearer`).
- `Api infomaniak.json` (spec OpenAPI officielle, licence MIT) est conservée comme référence.

## Compatibilité

- iOS 26.0+, iPhone & iPad
- Conçu pour **LiveContainer** : aucun entitlement exotique, pas de BGTaskScheduler,
  Keychain avec repli UserDefaults, IPA non signé produit par la CI.
