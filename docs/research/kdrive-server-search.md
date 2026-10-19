# kDrive : recherche serveur, intersection de catégories et tri

Recherche documentaire du 19 octobre 2026 — aucune requête authentifiée, aucun identifiant utilisé, aucune modification applicative ni exécution de tests/build/CI.

## Réponse simple

**Oui : l’API officielle documente une intersection de plusieurs catégories (ET), combinable avec une recherche textuelle dans une seule requête.** Ce n’est pas une syntaxe supposée : la documentation décrit les opérateurs et le client iOS officiel les utilise. **Mais le tri serveur documenté pour cette recherche est limité à la date de dernière modification et à la pertinence**, pas au nom ni à la taille. Un passage « 100 % serveur » pour tous les filtres et tris de l’application n’est donc pas démontré. [D][I]

**Recommandation : privilégier l’API native pour catégories + texte + tris pris en charge ; conserver un hybride explicite pour les règles spécifiques.** Un backend intermédiaire n’est justifié que si un index propre et ses coûts répondent à un besoin réel (tris globaux supplémentaires, recherche métier, volumes). Déplacer seulement les mêmes appels sur un serveur ne supprime pas les limites de kDrive.

## Niveau de preuve et méthode

- **Vérifié dans la documentation officielle** : contrat et limites ci-dessous. La page paraît vide avec l’extraction textuelle de `web_fetch`, mais son HTML public contient un attribut Inertia `data-page`. Après décodage HTML puis JSON, `props.operation.meta.parameters`, `responses` et `x-codeSamples` donnent le schéma de l’opération. Il s’agit du contenu de la même page officielle, pas d’une API privée ni d’un appel au Drive. [D]
- **Corroboré par le client officiel** : lecture du dépôt public iOS, figé au commit `639e43d85b2f3ecf8018e3acac4fe1d48bc31350`. Cela prouve l’encodage et l’intention du client, pas une mesure du serveur. [I]
- **Non vérifié en conditions réelles** : résultats sur ce compte, disponibilité des capacités, latence, cohérence de l’index, gestion exacte des accents, sous-chaînes, pagination pendant des modifications et comportement au-delà des limites. Aucun appel authentifié n’a été fait.
- Pas d’audit local large : les propositions d’architecture sont des recommandations, pas un constat détaillé de l’implémentation locale.

## Contrat exact établi

### Point d’entrée et intersection

`GET https://api.infomaniak.com/3/drive/{drive_id}/files/search` est le point d’entrée du schéma et de l’exemple curl officiels. Le client iOS utilise le même chemin sous son hôte `api.kdrive.infomaniak.com` ; la présente recommandation d’hôte repose sur la documentation publique, pas sur une équivalence réseau testée. [D][I]

| Besoin | Paramètre / sémantique vérifiée |
|---|---|
| Plusieurs catégories ET | Un seul paramètre chaîne `category=12&34` **avant encodage URL** : fichier appartenant aux catégories 12 et 34. |
| Catégories OU | Valeur `12|34`. |
| Expression composée | Parenthèses pour la priorité ; exemple officiel `(1&2)|3`. Longueur maximale de `category` : **200 caractères**. |
| Texte | `query=vacances` ; au moins **3 caractères recommandés** pour des résultats pertinents, et non une longueur minimale de validation démontrée. |
| Nom seulement | `query_scope=filename`, avec la réserve de capacité ci-dessous. |
| Périmètre | `directory_id` : dossier ciblé, racine par défaut ; `depth=child` ou `unlimited`. |

Source de toutes les lignes : [D]. Le client construit dans la **même fonction** `query` et `category`, avec `let separator = belongToAllCategories ? "&" : "|"`, puis joint les identifiants de catégories dans un `URLQueryItem(name: "category", ...)`. Il n’utilise pas `category[]`, ni `category_ids[]`, ni un paramètre séparé `operator=AND`. [I]

Exemple illustratif conforme au contrat, **non exécuté**, pour ET + texte + date décroissante :

```text
GET https://api.infomaniak.com/3/drive/{drive_id}/files/search?category=12%2634&query=vacances&query_scope=filename&depth=unlimited&order_by=last_modified_at&order_for%5Blast_modified_at%5D=desc&limit=60
```

**Important :** `%26` fait partie de la valeur de `category`. Écrire directement `category=12&34` dans une URL couperait les paramètres ; utiliser un encodeur de paramètres. Pour OU, la valeur encodée est `12%7C34`. [D][I]

### Recherche par nom : attention à ne pas promettre la même logique locale

La documentation donne `query_scope=all` (contenu et nom), `content` (contenu seulement), `filename` (nom seulement). **Elle conditionne explicitement `content` et `filename` à la capacité du Drive `can_use_content_search`.** Il faut conserver cette réserve, même si elle peut surprendre pour `filename`. L’ancien paramètre `name` est décrit comme limité au nom mais **déprécié** : ce n’est pas le choix recommandé pour une nouvelle intégration. [D]

`query` seul ne prouve donc pas une recherche strictement limitée au nom. Ni la documentation consultée ni la construction du client ne garantissent une équivalence exacte avec une recherche locale par sous-chaîne, sans accents ou sans distinction de casse. Le client iOS omet `query` lorsqu’il est vide ou blanc ; une recherche par catégories seules est prévue dans sa construction. [D][I]

### Tri : limitation importante

Pour **cet endpoint**, l’énumération officielle `order_by` contient uniquement : [D]

- `last_modified_at` ;
- `relevance`.

La direction est `order_for[last_modified_at]=asc` ou `desc` (même principe pour le champ demandé). Le helper générique iOS `sorted(by:)` encode `order_by` comme une liste séparée par des virgules et ajoute `order_for[champ]`. **Son caractère générique ne démontre pas que la recherche accepte `name`, `size` ou `updated_at`.** Aucun tri alphabétique global ou par taille ne doit être promis sur cette base. [D][I]

Le schéma décrit `order_by` comme un tableau (`style=form`, `explode=true`), alors que le helper iOS général utilise une liste séparée par des virgules. L’exemple proposé n’emploie qu’un champ, sans cette ambiguïté ; la sérialisation multi-tris sur la recherche n’a pas été validée en production. Ne pas confondre cette convention avec `order_by[]` + `order`, ni changer tous les endpoints sans vérifier leur propre contrat. [D][I]

### Pagination, total et autres limites

- Paramètres documentés : **`cursor` + `limit`**, et non `page` / `per_page` ; `limit` entre **5 et 1000**, valeur par défaut **10**. [D]
- Réponse de succès : `result`, `data`, `cursor` nullable, `has_more`, `response_at`. Transmettre le curseur retourné pour la suite ; **aucun total global n’est décrit dans cette réponse**. Ne pas transformer `data.count` en total de l’intersection. [D]
- Le schéma d’erreur 400 contient `results_set_too_large_error`, décrit par « Results set should not exceed 10000 elements. Invalid per_page / page attributes. » Cette mention de l’ancien couple page/per_page est incohérente avec les paramètres curseur affichés : elle impose une prudence sur les grands résultats, pas une conclusion inventée sur le comportement exact des curseurs au-delà de 10 000. [D]
- `with` permet notamment de demander `categories`, `categories.category`, `capabilities` ou `highlights`. Cela peut éviter des lectures supplémentaires quand ces données sont nécessaires ; leur coût n’a pas été mesuré. [D]
- Les catégories peuvent donc être croisées côté serveur ; cela ne prouve pas que les métadonnées vidéo spécialisées, l’orientation ou des critères métier propres à l’application sont recherchables côté serveur.

## Trois routes possibles

Les avantages et coûts ci-dessous sont une analyse d’architecture à partir du contrat établi, pas des performances mesurées.

| Route | Ce qu’elle apporte | Limites / coût | Avis |
|---|---|---|---|
| **1. API native** | Envoyer l’expression `category`, le texte et le tri autorisé ensemble ; l’iPhone reçoit directement des pages de l’intersection. Moins de filtrage local et pas de nouvelle infrastructure. [D][I] | Tris documentés restreints ; réserve sur le nom seul ; pas de total ; limites et sémantique réelle à confirmer. N’expose pas magiquement tous les filtres métier. | **Premier choix pour ET + texte + date/pertinence.** Ne pas annoncer tous les tris serveur. |
| **2. Optimiser l’hybride actuel** | Garder les règles locales indispensables et déléguer seulement les prédicats prouvés. Annuler les recherches obsolètes, réutiliser les métadonnées, dédupliquer, isoler les caches par critères et curseur. | Une page kDrive filtrée localement n’est pas une page complète de résultats finaux. Un tri local de pages partielles n’est pas un tri global. Pour exhaustivité/total/tri global supplémentaires, il faut parcourir tous les candidats nécessaires, avec coût réseau et mémoire. | **Complément pragmatique**, et solution de repli si la recherche native ne respecte pas le besoin précis. |
| **3. Backend intermédiaire** | Un index propre pourrait fournir intersection, nom, tris et total avec une sémantique maîtrisée ; mutualisation des calculs/cache entre appareils. | Synchronisation des catégories, noms, suppressions et droits ; risque de résultats périmés ; exploitation, hébergement, sécurité et gestion des accès. Un simple proxy garde les restrictions natives ; un vrai index peut dupliquer des métadonnées. Aucune garantie de flux de synchronisation complet n’a été étudiée ici. | **Pas nécessaire pour obtenir le ET**, déjà documenté. À envisager seulement si les besoins restants justifient cet investissement. |

Pour l’hybride, choisir une catégorie supposée moins fréquente peut réduire les candidats, mais un compteur d’utilisation n’est **ni un cardinal exact garanti ni une garantie de performance**. Le choix doit rester une heuristique, sans compromettre l’exhaustivité.

## Décision proposée et réserves avant une éventuelle réalisation

1. **Viser le natif d’abord** pour l’intersection de catégories, le texte et les tris réellement documentés ; ne pas construire un backend pour résoudre un ET déjà présent.
2. **Garder un périmètre hybride honnête** : tri alphabétique ou par taille global et filtres spécialisés ne sont pas établis ici côté serveur. Afficher une liste partielle comme telle si tous les candidats n’ont pas été chargés.
3. Si une réalisation est ensuite autorisée, vérifier séparément : capacité `query_scope=filename`, différences de correspondance locale/API, ordre des résultats, continuité des curseurs, limites de grands résultats et absence de double filtrage local divergent. Garder requête, catégorie, portée, tri et pagination cohérents dans le cache. **Ces validations n’ont pas été exécutées pendant cette recherche.**
4. N’envisager un index intermédiaire qu’après avoir identifié un besoin non satisfait et mesuré le coût réel ; aucun chiffre de gain ou de latence n’est avancé ici.

## Sources primaires

- **[D] Documentation Infomaniak — Search file/directory** : https://developer.infomaniak.com/docs/api/get/3/drive/%7Bdrive_id%7D/files/search — schéma embarqué dans le HTML (`props.operation`), consulté le 19 octobre 2026. Couvre endpoint/hôte, filtres, opérateurs, enum de tri, capacités, pagination, réponse et erreurs.
- **[I] Client iOS officiel — `Endpoint.swift`, commit figé** : https://github.com/Infomaniak/ios-kDrive/blob/639e43d85b2f3ecf8018e3acac4fe1d48bc31350/kDriveCore/Data/Api/Endpoint.swift — sections `Search`, `sorted(by:)`, `driveV3` et `ApiEnvironment.apiDriveHost`. Version brute consultée : https://raw.githubusercontent.com/Infomaniak/ios-kDrive/639e43d85b2f3ecf8018e3acac4fe1d48bc31350/kDriveCore/Data/Api/Endpoint.swift

Aucune source secondaire employée. Les conclusions restent limitées au contrat officiel et à l’encodage observé dans le client iOS ; elles ne remplacent pas un essai réel sur le compte concerné.
