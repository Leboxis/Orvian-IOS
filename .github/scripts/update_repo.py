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

CHANGELOG = """v0.8.1
• Profil : correction de l'endpoint kDrive /files/recent et fallback automatique /files/last-modified
• Profil : affichage immédiat et réactif des 3 médias les plus consultés lors du changement d'onglet

v0.8.0
• Suivi d'upload en direct : bulle flottante centrale au-dessus de la barre de navigation et feuille détaillée
• Traqueur de médias 100% persistant : enregistrement local des médias les plus consultés conservé après fermeture
• Navigation rapide : retour instantané à la base de l'onglet par double-tap sur son icône
• Profil : filtrage strict garantissant uniquement des fichiers réels dans les uploads récents et médias consultés

v0.7.9
• Accueil : bouton filtre déplacé à gauche et nouveau bouton « Dé » pour ouvrir un fichier aléatoire
• Profil : sections « Uploads récents » et « Favoris » avec 3 miniatures et vue dédiée paginée par 12 à l'infini
• Lecteur vidéo : vitesse de lecture modifiable en continu et correction de la fuite audio à la fermeture
• Import de fichiers : support des clés USB et iCloud Drive (Security-Scoped Resources)
• Visionneuse photo : déplacement borné lors du zoom et renommage sans saut d'écran"""


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
