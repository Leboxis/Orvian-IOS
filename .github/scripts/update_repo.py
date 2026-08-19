"""Régénère repo.json (source AltStore/LiveContainer) pour la version donnée.

Usage: python3 update_repo.py <version> <tag> <size_octets> [version_date] [notes]
Exemple: python3 update_repo.py 0.4.0 v0.4.0 596772 2026-08-16 "• Correction importante"

Écrit le JSON sur stdout. Les notes de la nouvelle version sont fournies par
la CI ; l'historique de référence reste dans la constante HISTORY.
"""
import json
import sys

REPO = "Leboxis/Orvian-IOS"
ICON = "https://raw.githubusercontent.com/Leboxis/Orvian-IOS/refs/heads/main/Orvian/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

HISTORY = """v0.8.16
• Sélection multiple : interface supérieure simplifiée avec compteur centré
• Déplacement : bouton toujours visible dans la barre de navigation
• Affichage : suppression de la barre d’action masquée par la navigation flottante

v0.8.15
• Déplacement : action disponible après un appui long sur une carte
• Sélection multiple : déplacement groupé vers un dossier choisi dans l’arborescence
• Sécurité : destinations invalides masquées et gestion des échecs partiels

v0.8.14
• Favoris : cartes sans étoile redondante et effets graphiques allégés
• Défilement : préchargement des miniatures et URL vidéo régulé selon la position visible

v0.8.13
• Accueil : racine remontée d'un niveau tout en bloquant le retour au niveau supérieur

v0.8.12
• Source LiveContainer : chemin Git explicite pour éviter une ancienne réponse mise en cache

v0.8.11
• Accueil : la racine démarre un niveau plus bas, sans retour vers l'ancien niveau
• Uploads : correction du suivi, du nettoyage temporaire et des blocages du thread principal
• Vidéo : démarrage de la lecture sans attendre le poster ni les tags

v0.8.8
• AirPlay vidéo : correction de la diffusion vers les écrans externes (Apple TV, AirPlay 2)
• Lecteur vidéo : décalage supplémentaire de 4 points vers les extrémités et titre centré d'origine

v0.8.7
• Téléchargement : ajout de l'option « Télécharger » (appui long et feuille de détails) avec partage natif iOS
• Lecteur vidéo : boutons haut/bas et barre de lecture décalés vers les extrémités

v0.8.6
• Profil & Réglages : ajout d'une marge basse pour faire défiler la section À propos au-dessus de la barre de navigation
• Lecteur vidéo : commandes décalées vers les bords

v0.8.5
• Uploads récents : utilisation de l'endpoint kDrive exact /files/last_modified avec cascade de fallbacks
• Lecteur vidéo : masquage automatique des commandes au bout de 2.5s et réaffichage au clic"""


def main() -> int:
    version, tag, size, version_date = sys.argv[1:5]
    notes = sys.argv[5] if len(sys.argv) > 5 else "• Version publiée automatiquement depuis main"
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # Windows : évite cp1252
    source = {
        "name": "Orvian",
        "identifier": "com.orvian.repo",
        "website": f"https://github.com/{REPO}",
        "subtitle": "Client iOS non officiel pour kDrive (Infomaniak)",
        "description": "IPA non signés d'Orvian, prêts pour LiveContainer.",
        "tintColor": "#4285F5",
        "iconURL": ICON,
        "apps": [
            {
                "name": "Orvian",
                "bundleIdentifier": "com.orvian.app",
                "developerName": "Leboxis",
                "subtitle": "Client kDrive non officiel",
                "version": version,
                "versionDate": version_date,
                "versionDescription": f"v{version}\n{notes}\n\n{HISTORY}",
                "downloadURL": f"https://github.com/{REPO}/releases/download/{tag}/Orvian-{version}-unsigned.ipa",
                "localizedDescription": (
                    "Client iOS natif non officiel pour kDrive (Infomaniak) : navigation dans "
                    "l'arborescence, favoris, tags, visionneuse photo et vidéo, import de fichiers, "
                    "photos et vidéos."
                ),
                "iconURL": ICON,
                "tintColor": "#4285F5",
                "category": "utilities",
                "size": int(size),
            }
        ],
    }
    json.dump(source, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
