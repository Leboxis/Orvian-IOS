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

CHANGELOG = """v0.7.7
• Recherche ciblée sur le dossier actuel et ses sous-dossiers
• Recherche multi-mots combinant l'ensemble des termes dans le nom du fichier
• Bulle de chemin (breadcrumbs) avec compteur d'éléments toujours visible et rehaussée sous le titre
• Bouton Trier accessible lors de l'exploration des fichiers d'un tag

v0.7.6
• Corbeille : miniatures, restauration et ouverture des fichiers, barre de sélection compacte
• Barre de recherche : apparition fluide au défilement
• Import de fichiers via document picker UIKit
• Tri des tags par récence d'utilisation et création avec palette de couleurs

v0.5.0
• Lecteur vidéo personnalisé : barres hors de la zone de lecture, play/pause, barre de progression, muet, AirPlay, favori, choix d'un tag
• Étoile dorée sur les cartes des favoris, pastilles colorées des tags à côté du poids
• Bouton « + » déplacé à droite, import de fichiers hors du thread principal
• Accueil ouvert automatiquement dans le premier dossier de la racine"""


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
