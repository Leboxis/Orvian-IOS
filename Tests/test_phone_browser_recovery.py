"""Nonvisual contracts for iPhone readability and visible search state."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class PhoneBrowserRecoveryChecks(unittest.TestCase):
    def test_file_names_wrap_in_both_presentations(self):
        text = source("Orvian/Features/Shared/FileCardView.swift")
        content = text[text.index("@ViewBuilder private var cardContent:"):text.index("private var thumbnailArea:")]
        list_name = content[content.index("Text(file.name)"):content.index("Text(!showsListMetadata")]
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)", list_name)
        self.assertIn(".lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2, reservesSpace: true)", content)
        self.assertNotIn(".clipped()", content)

    def test_active_query_cannot_be_hidden_by_dismissal(self):
        for path in ["Orvian/Features/Home/DirectoryView.swift",
                     "Orvian/Features/Favorites/FavoritesView.swift"]:
            with self.subTest(path=path):
                text = source(path)
                visibility = text[text.index("private var searchBarVisible:"):]
                visibility = visibility[:visibility.index("\n    }")]
                self.assertIn("isSearching || (!searchDismissed", visibility)
                dismiss = text[text.index("private func dismissSearch()"):]
                dismiss = dismiss[:dismiss.index("\n    }")]
                self.assertIn("searchFocused = false", dismiss)
                self.assertNotIn('searchText = ""', dismiss)
                self.assertIn('"Masquer le clavier"', text)
                self.assertIn('accessibilityLabel("Effacer la recherche")', text)

    def test_folder_keeps_identity_when_path_is_hidden(self):
        text = source("Orvian/Features/Home/DirectoryView.swift")
        header = text[text.index(".modifier(FileBrowserHeader"):text.index("        .toolbar {")]
        self.assertIn("if showBreadcrumb", header)
        self.assertIn("} else {\n                        Text(directory.name)", header)
        self.assertIn(".accessibilityAddTraits(.isHeader)", header)


if __name__ == "__main__":
    unittest.main()
