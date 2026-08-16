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

CHANGELOG = """v0.7.9
• Accueil : bouton filtre déplacé à gauche et nouveau bouton « Dé » pour ouvrir un fichier aléatoire
• Profil : sections « Uploads récents » et « Favoris » avec 3 miniatures et vue dédiée paginée par 12 à l'infini
• Lecteur vidéo : vitesse de lecture modifiable en continu et correction de la fuite audio à la fermeture
• Import de fichiers : support des clés USB et iCloud Drive (Security-Scoped Resources)
• Visionneuse photo : déplacement borné lors du zoom et renommage sans saut d'écran

v0.7.8
• Défilement ultra-fluide (60/120 FPS) : accès mémoire synchrone des miniatures et suppression des micro-gels
• Décompression directe GPU hors du thread principal pour les photos et vidéos
• Suppression des écritures disque superflues lors de la lecture du cache
• Isolation des résolutions de métadonnées vidéo pour éviter les rafraîchissements intempestifs

v0.7.7
• Recherche ciblée sur le dossier actuel et ses sous-dossiers
• Recherche multi-mots combinant l'ensemble des termes dans le nom du fichier
• Bulle de chemin (breadcrumbs) avec compteur d'éléments toujours visible et rehaussée sous le titre
• Bouton Trier accessible lors de l'exploration des fichiers d'un tag"""


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
