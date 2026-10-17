# Choix d'interface protégés — autorisation explicite obligatoire

- Ordre des onglets, sur iPhone et iPad : Réglages — Tags — Accueil — Favoris — Profil.
- Accueil, Favoris et contenu des Tags : deux boutons séparés en haut à droite,
  Hasard à gauche et Sélectionner à droite. Ne pas les regrouper dans un menu
  ni intercaler une autre commande entre eux.
- Ne modifier ces deux choix que sur autorisation explicite de l'utilisateur.
  Conserver les tests `test_protected_navigation.py` ; un nouveau design n'est
  pas une autorisation de les contourner.
- Ne pas lancer de vérification visuelle ou de captures via GitHub Actions.
  Les tests non visuels restent autorisés. Signaler les limites de validation iOS.
