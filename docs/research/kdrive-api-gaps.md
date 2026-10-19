# kDrive : ce que l'API offre et que l'app n'utilise pas

Analyse du 19 octobre 2026, à partir du fichier `Api infomaniak.json` présent à la
racine du dépôt (OpenAPI 3.1, 145 chemins, 183 opérations) comparé au code de
`Orvian/`. Aucun appel authentifié, aucune modification applicative.

## Méthode et limites

- L'app utilise **37 opérations** ; le fichier en décrit **183**. Le reste est
  listé ci-dessous, classé par bénéfice produit.
- Le fichier est **incomplet** : il ne contient ni
  `POST /2/drive/{id}/files/{file_id}/color` (utilisé par l'app), ni
  `/files/notifications` (utilisé par le client iOS officiel). **Absence du
  fichier ≠ absence de l'API.** Chaque ajout doit donc être confirmé sur le
  compte réel avant d'être promis.
- Les capacités sont liées à l'offre : `can_use_content_search`, `use_versioning`,
  `can_rewind`, `can_set_sharelink_password`… proviennent de
  `drive.capabilities` / `drive.pack.capabilities`. Aucune n'a été vérifiée ici.
- Pagination des listes v3 : `cursor` + `limit` (5 à 1000), pas de total ;
  la recherche est bornée à ~10 000 résultats.

## 1. Le gisement gratuit : des champs déjà reçus et jetés

`FileV3` déclare ces champs comme **toujours renvoyés**. `DriveFile` ne les
décode pas : ils sont perdus au décodage, sans requête supplémentaire ni octet
de plus.

| Champ | Ce qu'il apporte dans « Détails » | Effort |
|---|---|---|
| `created_at` | Date de création, distincte d'« Ajouté » | S |
| `created_by` | Auteur du fichier (identifiant) | S |
| `last_modified_by` | Dernier modificateur, distinct de la date | S |
| `revised_at` | Dernière révision du **contenu** (vs `updated_at` qui couvre aussi renommage/déplacement) | S |
| `scan_status` | Analyse antivirus : `clean`, `infected`, `pua`, `cannot_be_scanned`… | S |
| `status` | `locked`, `ok`, `uploading`, `trashed` — explique un fichier non modifiable | S |
| `visibility` | Espace privé / partagé / équipe — le contexte du fichier | S |
| `depth` | Profondeur dans l'arborescence | S |

Puis, en ajoutant les valeurs correspondantes à `with=`, sans nouvelle route :

| Valeur de `with` | Gain | Effort |
|---|---|---|
| `capabilities` | `can_delete`, `can_rename`, `can_move`, `can_share`, `can_use_favorite`, `can_write`… : griser au lieu d'échouer. Le client officiel le demande par défaut (`FileWith.fileMinimal`). | M |
| `version` | `number`, `is_multiple`, `total_size` (taille versions incluses) : « 7 versions · 240 Mo au total » | S |
| `hash` | Empreinte du contenu, utile pour vérifier un téléchargement | S |
| `sharelink` | Savoir si un lien public existe, sans requête dédiée | S |
| `supported_by` | Applications capables d'ouvrir le fichier (365, onlyoffice, drawio…) | S |
| `parents` | Chaîne complète des dossiers parents, pour un fil d'Ariane | M |
| `users`, `teams` | Identifiants ayant accès, préalable à un écran de partage | M |

`GET /2/drive/{id}/files/{file_id}/hash` existe aussi seul, si le hash n'est pas
dans la liste.

## 2. Menu Détails : les blocs absents

| Endpoint | Ce que ça donnerait | Effort |
|---|---|---|
| `GET /2/drive/{id}/files/{file_id}/versions` | Historique : date, taille, auteur, `keep_forever` par version | M |
| `POST /2/…/versions/{version_id}/restore` | Restaurer une version (et `…/restore/{dir}` vers un dossier) | M |
| `GET /2/…/versions/{version_id}/download` | Récupérer une ancienne version sans la restaurer | M |
| `PUT /2/…/versions/current` | Épingler la version courante (`keep_forever`) | S |
| `GET /2/drive/{id}/files/{file_id}/comments` | Fil de commentaires, réponses, likes, résolution | L |
| `GET /2/drive/{id}/files/{file_id}/access` | Qui a accès : utilisateurs, équipes, invitations, `parent_access` | M |
| `GET /2/drive/{id}/files/{file_id}/link` | État du lien public : droit, expiration, mot de passe, statistiques | M |
| `GET /3/drive/{id}/files/{file_id}/activities` | Journal du fichier : créé, renommé, déplacé, mis en corbeille, commenté | M |
| `GET /2/drive/{id}/files/{file_id}/preview?as=pdf` | Aperçu convertible (Office → PDF, texte) pour les types que QuickLook refuse | M |
| `GET /2/drive/{id}/files/{file_id}/download?as=pdf` | Télécharger une version convertie | M |

Les versions ne valent que si `drive.capabilities.use_versioning` est vrai ;
les commentaires et le partage ne valent que si `can_share` / `can_use_team`.

## 3. Recherche : sept filtres serveur inexploités

L'app n'envoie que `query`, `directory_id`, `depth=unlimited` et, pour les tags,
`category`. Le même endpoint accepte :

| Paramètre | Usage concret | Effort |
|---|---|---|
| `types[]` | `image`, `video`, `pdf`, `dir`, `spreadsheet`… filtre exact et paginé côté serveur, au lieu du filtrage local sur la page chargée | S |
| `extensions[]` | « seulement .heic et .jpg » | S |
| `modified_at` | Préréglages : `today`, `yesterday`, `last_7_days`, `last_30_days`, `this_month`, `last_year`… | S |
| `modified_after` / `modified_before` | Période personnalisée (`modified_at=custom` obligatoire) | S |
| `author_id` | « fichiers de untel » | M |
| `query_scope` | `filename` (nom seul) ou `content` (contenu) — ce dernier exige `can_use_content_search` | M |
| `category` | Déjà utilisé ; accepte `(1&2)|3` jusqu'à 200 caractères | — |

**Limite à ne pas ignorer** : sur `/files/search`, `order_by` n'accepte que
`last_modified_at` et `relevance`. Les tris nom/taille/type y restent locaux —
ne pas promettre un tri global.

## 4. Vues entières qui manquent

| Endpoint | Écran possible | Effort |
|---|---|---|
| `GET /3/drive/{id}/files/shared_with_me` | « Partagés avec moi », avec filtre `type=dir|file|vault` | M |
| `GET /3/drive/{id}/files/my_shared` | « Mes partages » | M |
| `GET /3/drive/{id}/files/links` | « Liens publics », triable par `expires_at`, `has_password` | M |
| `GET /3/drive/{id}/files/largest` | « Plus gros fichiers » — le pendant naturel du poids des dossiers déjà ajouté | S |
| `GET /3/drive/{id}/files/most_versions` | « Fichiers les plus versionnés » (garde-fou d'espace) | S |
| `GET /3/drive/{id}/files/dropboxes` | Dossiers de dépôt publics (voir §7) | M |
| `GET /3/drive/{id}/trash/{file_id}/files` | Parcourir un dossier mis à la corbeille (aujourd'hui impossible) | M |
| `GET /2/drive/{id}/activities` | Journal du drive : qui a fait quoi, filtres `actions[]`, `users[]`, `from`/`until` | L |

`/files/activities` (racine) est déjà utilisé comme repli de « récents » ;
`/3/drive/{id}/activities` est un flux d'audit distinct.

## 5. Actions de fichier manquantes

| Endpoint | Action | Effort |
|---|---|---|
| `POST /3/…/files/{file_id}/duplicate` | Dupliquer sur place (nom optionnel) | S |
| `POST /3/…/files/{file_id}/copy/{destination_directory_id}` | Copier vers un dossier — aujourd'hui seul « Déplacer » existe | S |
| `POST /2/…/files/{file_id}/copy-to-drive` | Copier **entre drives** (`source_drive_id`, `source_file_id`) | M |
| `POST /3/…/files/{file_id}/convert` | Convertir le contenu | M |
| `POST /3/…/files/{file_id}/file` | Créer un fichier vide : `docx`, `docxf`, `drawio`, `pptx`, `txt`, `xlsx` | S |
| `POST /3/…/files/team_directory` | Créer un dossier d'équipe (`for_all_user`, couleur) | S |
| `POST /3/…/files/archives` | Zipper une sélection hétérogène puis
`GET /2/…/files/archives/{uuid}` — le vrai « Télécharger tout » | M |
| `POST /2/drive/{id}/cancel` | **Annuler** une suppression, un renommage ou un déplacement | S |
| `POST /3/drive/{id}/wake` | Réveiller un drive en veille (`drive_is_in_maintenance_error`) | S |
| `DELETE /3/…/files/{file_id}/lock` | Déverrouiller un fichier tenu par Office/WebDAV | S |

**Le meilleur rapport effort/impact** est `POST /cancel` : les réponses de
`DELETE /files/{file_id}`, `POST /rename` et `POST /move/…` renvoient déjà un
`CancelResource` (`cancel_id`, `valid_until`) que `sendEmpty` jette. Un bandeau
« Annuler » après une suppression ou un renommage ne demande qu'à lire ce corps
et à l'envoyer à `/cancel`.

## 6. Corbeille

| Endpoint | Gain | Effort |
|---|---|---|
| `DELETE /2/drive/{id}/trash` | **Vider la corbeille** — absent de `TrashView` | S |
| `GET /2/drive/{id}/trash/count` | Badge de quantité dans Profil | S |
| `GET /3/…/trash/{file_id}` | Détails d'un élément corbeillé (l'app ne charge pas sa fiche) | S |
| `GET /3/…/trash/{file_id}/count` | Nombre d'éléments d'un dossier corbeillé | S |
| `GET /3/…/files/search/trash` | Rechercher **dans** la corbeille (`query`, `deleted_at`, `deleted_by`) | M |
| `GET /2/…/trash/{file_id}/activities` | Historique d'un élément supprimé | M |

## 7. Partage, collaboration, accès

| Endpoint | Gain | Effort |
|---|---|---|
| `POST` / `PUT` / `DELETE /2/…/files/{file_id}/link` | Créer, modifier, révoquer un lien public : `right` (`inherit`/`password`/`public`), `valid_until`, mot de passe, `can_download`, `can_edit`, `can_comment`, `can_see_stats` | L |
| `POST /2/…/files/{file_id}/link/invite` | Inviter par lien | M |
| `POST /2/…/files/{file_id}/access` | Partager avec des e-mails, `user_ids`, `team_ids`, droit `read`/`write`/`manage` | L |
| `GET /2/…/files/{file_id}/access/users` / `/teams` / `/invitations` | Listes d'accès détaillées | M |
| `GET /2/drive/{id}/access/requests/{request_id}` + `PUT …/decline` | Traiter les **demandes d'accès** reçues | M |
| `POST /2/…/access/applications` | Ouvrir dans 365 / Collabora (`mode=view|edit`) | M |
| `POST /2/…/files/{file_id}/dropbox` | Transformer un dossier en **dépôt public** (dépôt de fichiers par des anonymes) | M |

## 8. Commentaires (bloc complet, aujourd'hui absent)

`GET` / `POST /comments`, `GET` / `PUT` / `DELETE /comments/{comment_id}`,
`POST /comments/{comment_id}` (réponse), `POST …/like`, `POST …/unlike`.
Le schéma porte `is_resolved`, `responses_count`, `likes_count`, `parent_id` :
fil de discussion avec résolution. Effort L (écran + pagination + temps réel
absent).

## 9. Drive, compte, administration

| Endpoint | Gain | Effort |
|---|---|---|
| `GET /2/drive/{id}` | `role`, `quota`, `capabilities`, `settings`, `pack` : la source des capacités ci-dessus | S |
| `GET /2/drive/{id}/settings` | `versioning_days`, rétention corbeille, options Office/IA | S |
| `PUT /2/drive/{id}/settings/trash` | Changer la rétention de la corbeille (admin) | M |
| `GET /2/drive/{id}/users` + CRUD | Gérer les membres, invitations, verrouillage, droit manager | L |
| `GET /2/drive/{id}/statistics/sizes` | Répartition de l'espace par dossier (graphe) | M |
| `GET /2/drive/{id}/statistics/activities*` | Activité par utilisateur / fichiers partagés / liens | L |
| `GET /2/drive/{id}/activities/reports` | Rapports d'activité exportables | L |
| `GET` / `PATCH /2/drive/preferences` | Préférences kDrive côté serveur (page d'accueil, couleur) | S |
| `GET /2/drive/users` + `/users/{user_id}/drives` | Comptes et drives d'un autre utilisateur | M |
| `POST /2/drive/{id}/imports/*` | Importer depuis un lien kDrive, WebDAV, OAuth2 (Dropbox, OneDrive…) | L |
| `GET /2/drive/{id}/categories/rights` + `POST` | Qui peut gérer les tags | M |
| `POST /2/…/categories/{category_id}/ai-feedback` | Valider un tag proposé par l'IA | S |

## 10. Divers utile, peu coûteux

| Endpoint | Gain | Effort |
|---|---|---|
| `POST /2/drive/{id}/files/exists` | Vérifier en un appel qu'une sélection existe encore (avant un déplacement massif) | S |
| `GET /3/drive/{id}/activities/total` | Compter les activités sans paginer | S |
| `GET /3/drive/{id}/files/search/{favorites,links,dropboxes,shared_with_me,my_shared,trash}` | Variantes de recherche **déjà filtrées** par nature, avec `query` et `category` | M |
| `POST /3/…/upload/session/batch/start` + `…/batch/finish` + `DELETE /2/…/upload/session/batch` | Ouvrir/fermer plusieurs sessions d'upload en un appel (gros lots) | M |
| `GET /2/…/upload/session/{token}?with=chunks` | Reprendre un upload interrompu après relance de l'app | M |

## 11. Pièges à éviter

1. **`order_by` de la recherche** : `last_modified_at` et `relevance` seulement.
   Tout tri « nom / taille / type » reste local sur les pages chargées.
2. **`query_scope=filename` et `content`** sont conditionnés à
   `can_use_content_search` ; sans la capacité, l'app garde sa recherche locale.
3. **`query` court** : moins de 3 caractères donne des résultats peu pertinents.
   Le debounce actuel de 300 ms est le bon endroit pour attendre.
4. **Pas de total** sur les listes v3 : ne pas transformer `data.count` en total.
   `count` reste l'endpoint dédié (et il accepte `depth=unlimited`, que l'app
   n'envoie pas encore : le compteur affiché est celui du premier niveau).
5. **`with=` change la charge** : `capabilities` + `sharelink` + `users` sur
   chaque page alourdit les listes de 60 éléments. Les demander sur la fiche
   (`fileInfo`), pas dans la grille.
6. **Les mutations sont réversibles** : `CancelResource` n'est valable que
   quelques secondes (`valid_until`). Un bandeau doit expirer tout seul.
7. **Capacités non vérifiées** : aucune de ces routes n'a été appelée sur le
   compte réel pendant cette analyse.

## 12. Ordre suggéré

1. **Gratuit, zéro requête** : décoder `created_at`, `revised_at`, `scan_status`,
   `status`, `visibility`, `last_modified_by` et les afficher dans Détails (§1).
2. **Annuler** une suppression / un renommage / un déplacement (§5) : un bandeau,
   une route déjà présente dans la réponse.
3. **Corbeille** : vider, compter, parcourir un dossier corbeillé (§6).
4. **Recherche** : `types[]`, `extensions[]`, `modified_at` (§3) — trois menus,
   aucun changement d'architecture.
5. **Détails** : versions et hash (§2), puis `capabilities` pour griser les
   actions interdites.
6. **Vues** : plus gros fichiers, partagés avec moi, liens publics (§4).
7. **Partage** : lien public puis accès (§7) — le plus gros chantier produit.
