"""Boucle de feedback (skill diagnosing-bugs, phase 1) pour la bande bas d'ecran iPhone.

Symptome utilisateur : une « ligne »/voile du bas de l'app, par-dessus le
contenu du drive mais sous la barre de navigation flottante (pillule des
onglets). Cause : sur iPhone les overlays bas (pillule + bouton « + ») sont
ancrees au bas de l'ecran (viewport en ignoresSafeArea) avec un simple
`.padding(.bottom, 4)` : la pillule chevauche la home indicator et une bande
pleine largeur reste visible autour/sous elle.

Invariant attendu (iPhone uniquement, sans toucher l'ordre protege des
onglets ni les boutons Hasard/Selectionner) :
- l'overlay de navigation mesure la hauteur du chrome AVANT la reserve de
  safe area (sinon FileGridView, qui ajoute deja phoneBrowserBottomInset,
  compterait deux fois) ;
- l'overlay de navigation, puis les overlays « + » de DirectoryView et
  FavoritesView, remontent au-dessus de la safe area via
  `.safeAreaPadding(.bottom, ...)` ;
- phoneBottomChromeHeight reste la source unique transmise au contenu.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def iphone_overlay_block(source, marker):
    start = source.index(marker)
    # Bloc limite : l'overlay iPhone tient en quelques dizaines de lignes.
    return source[start:start + 2000]


class PhoneBottomChromeTests(unittest.TestCase):
    def test_tab_overlay_anchors_above_safe_area_after_measuring(self):
        main = read("Orvian/App/MainTabView.swift")
        block = iphone_overlay_block(main, ".overlay(alignment: .bottom)")
        self.assertIn("bottomNavigationChrome", block)
        self.assertIn("onGeometryChange", block)
        self.assertIn("safeAreaPadding(.bottom,", block,
                      "L'overlay iPhone doit remonter au-dessus de la home indicator")
        self.assertLess(block.index("onGeometryChange"), block.index("safeAreaPadding(.bottom,"),
                        "La mesure du chrome doit exclure la reserve de safe area")

    def test_add_button_overlays_stack_above_chrome_and_safe_area(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                source = read(path)
                block = iphone_overlay_block(source, ".overlay(alignment: .bottom)")
                self.assertIn(".padding(.bottom, phoneBottomChromeHeight)", block)
                self.assertIn("safeAreaPadding(.bottom,", block,
                              f"{path} : le bouton bas doit suivre le chrome + la safe area")
                self.assertLess(block.index(".padding(.bottom, phoneBottomChromeHeight)"),
                                block.index("safeAreaPadding(.bottom,"),
                                "La reserve de safe area s'ajoute apres le chrome mesure")

    def test_content_still_reserves_chrome_and_safe_area_once(self):
        grid = read("Orvian/Features/Shared/FileGridView.swift")
        self.assertIn("phoneBottomChromeHeight + contentBottomInset + phoneBrowserBottomInset", grid,
                      "FileGridView garde la formule unique : chrome + controles + safe area")


if __name__ == "__main__":
    unittest.main()
