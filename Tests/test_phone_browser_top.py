"""Boucle de feedback pour la « ligne » du haut sur iPhone.

Symptome (capture annotee) : un bandeau blanc pleine largeur entre la barre
d'outils systeme (blanche, opaque) et le contenu groupe du drive, avec le
liseret bas de la barre qui tranche. Le gris en dessous se lit comme un
filtre pose de cette ligne jusqu'en bas de l'app.

Invariant attendu (iPhone uniquement, sans toucher l'ordre protege des
onglets ni les boutons Hasard/Selectionner, qui restent dans la toolbar) :
les navigateurs de fichiers au titre vide (Accueil/dossiers, Favoris/tags)
fondent le fond de leur barre de navigation sur iPhone pour retrouver la
surface groupee continue ; l'iPad garde le comportement natif.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

PHONE_BAR = re.compile(
    r"\.toolbarBackground\([^)]*iPadLayout\.isPad[^)]*\.hidden[^)]*for: \.navigationBar[^)]*\)"
)


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhoneBrowserTopTests(unittest.TestCase):
    def test_phone_browsers_melt_the_bar_into_grouped_content(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                self.assertRegex(
                    read(path), PHONE_BAR,
                    f"{path} : la barre de navigation iPhone doit adopter "
                    "le fond du contenu groupe (iPad inchange)")

    def test_browsers_keep_an_empty_inline_title(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                source = read(path)
                self.assertIn('.navigationTitle("")', source)
                self.assertIn(".navigationBarTitleDisplayMode(.inline)", source)


if __name__ == "__main__":
    unittest.main()
