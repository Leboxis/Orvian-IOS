"""Régénère repo.json (source AltStore/LiveContainer) pour la version donnée.

Usage: python3 update_repo.py <version> <tag> <size_octets> [version_date]
Exemple: python3 update_repo.py 0.4.0 v0.4.0 596772 2026-08-16

Écrit le JSON sur stdout. Le contenu du changelog doit être maintenu dans
la constante CHANGELOG (dernière version en premier).
"""
import json
import sys

REPO = "Leboxis/Orvian-IOS"
ICON = "https://raw.githubusercontent.com/Leboxis/Orvian-IOS/main/Orvian/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

CHANGELOG = """v0.8.8
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
                "versionDescription": CHANGELOG,
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
