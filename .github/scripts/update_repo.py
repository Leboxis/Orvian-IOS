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

CHANGELOG = """v0.8.4
• Filtre : orientation vidéo à sélection unique et exclusive
• Tris : ajout des tris natifs par date de modification et par date d'importation
• Tags : renommage et suppression des tags (menu contextuel et swipe)
• Tags : sélecteur de couleur personnalisée avec palette système lors de la création

v0.8.3
• Uploads récents : correction définitive de l'erreur HTTP 404 via la recherche globale récursive et tri chronologique
• Profil : taille des 3 cartes miniatures strictement harmonisée et carrée pour tous types d'images et vidéos

v0.8.2
• Profil : suppression de l'adresse email, de la zone Drive et du lien API externe pour une interface épurée
• Réglages : déplacement de l'action « Changer de token / Se déconnecter » dans l'onglet Réglages

v0.8.1
• Profil : affichage immédiat et réactif des 3 médias les plus consultés lors du changement d'onglet"""


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
