# Vérification iOS des corrections d'audit

Les tests automatisés s'exécutent sur le runner macOS, en mode Swift 5 :

```sh
python3 .github/scripts/check_ios_regressions.py
python3 .github/scripts/check_favorites_cache.py
```

Le build Xcode complet suit ces contrôles dans le workflow existant. Ces tests
utilisent des secrets factices et des transferts simulés, sans compte kDrive.

## Parcours à vérifier sur iPhone / simulateur

- Installation existante : le PIN continue à déverrouiller ; sa première
  vérification réussie remplace l'ancienne empreinte par PBKDF2 salé.
- Keychain indisponible (LiveContainer) : le jeton n'est jamais réécrit dans
  UserDefaults. La connexion fonctionne pendant la session ; les réglages
  indiquent qu'une reconnexion sera nécessaire. Le PIN dérivé reste utilisable
  après redémarrage même sans Keychain.
- Cinq PIN incorrects : délai de 30 secondes affiché, touches désactivées.
  Relancer l'app conserve le délai. Une nouvelle erreur après le délai le
  double, jusqu'à une heure. Un bon PIN ou Face ID remet le compteur à zéro.
  Vérifier aussi le changement et la désactivation du PIN dans Réglages.
- Deux drives / comptes avec le même numéro de fichier : les métadonnées et
  filtres restent propres à chaque vidéo, y compris après une réponse tardive.
- Annuler un téléchargement immédiatement puis en cours de transfert : un
  nouveau téléchargement reste possible, aucune feuille de partage ne s'ouvre
  pour le fichier annulé. Annuler un envoi ne laisse pas une attente suspendue.
- Document texte de 5 Mio : ouverture et recherche de liens, défilement et
  édition. Document trop grand : erreur compréhensible, y compris sans taille
  annoncée par le serveur. Mesurer la réactivité sur l'iPhone le moins puissant.
- Mode avion avec tags non chargés : message d'échec et bouton Réessayer dans
  la fiche et l'éditeur ; aucun état vide trompeur ni modification à l'aveugle.
  Après reconnexion, les tags et leurs coches apparaissent correctement.
- Lot d'envois avec un échec : pourcentage tenant compte seulement des progrès
  réussis, puis « Erreur de transfert » à la fin.
- Panneau de filtres : un tap en dehors du panneau le referme ; retaper le
  bouton filtre le referme aussi. Déplier « Trier par », choisir un tri, puis
  taper dehors : le panneau se ferme (aucun menu imbriqué ne doit rester).
- Vérifier les nouveaux messages en mode clair/sombre et avec une grande
  taille de texte, sans débordement ni commande inaccessible.

## Limite de validation locale

Les changements ont été préparés sous Windows : la vérification syntaxique
ne remplace pas la compilation Xcode, les tests Swift et les essais ci-dessus.
