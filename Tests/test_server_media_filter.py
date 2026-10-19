"""Contrats du filtre média délégué au serveur (types[]), sans rendu.

Ces vérifications portent sur le code de production : la décision de déléguer
ou non, la forme de la requête et l'invalidation du curseur. Le comportement
réseau réel de l'API kDrive n'est pas exercé ici.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class ServerMediaFilterTests(unittest.TestCase):
    def setUp(self):
        self.filters = source("Orvian/Models/FileFilters.swift")
        self.sources = source("Orvian/Core/API/FileSource+Ordering.swift")
        self.endpoints = source("Orvian/Core/API/Endpoints.swift")
        self.service = source("Orvian/Core/API/KDriveService+Files.swift")
        self.model = source("Orvian/Features/Shared/FileGridViewModel.swift")
        self.grid = source("Orvian/Features/Shared/FileGridView.swift")
        self.cache = source("Orvian/Core/Cache/DirectoryListStore.swift")

    def test_only_search_endpoints_receive_types(self):
        # `types[]` n'est documenté que sur /files/search. L'envoyer à une
        # liste ferait croire à un filtrage serveur qui n'a pas eu lieu.
        block = self.sources[self.sources.index("var supportsServerMediaTypes: Bool"):]
        block = block[:block.index("\n    }")]
        self.assertIn("case .search, .intersection, .category: return true", block)
        self.assertIn("default: return false", block)

    def test_selection_is_expressible_or_stays_local(self):
        for case, expected in [(".videos", '["video"]'), (".images", '["image"]'),
                               (".folders", '["dir"]')]:
            self.assertIn(f"case {case}: return {expected}", self.filters)
        self.assertIn("case .all: return nil", self.filters)
        self.assertIn("case .other: return nil", self.filters)
        self.assertIn("func serverHandlesMedia(_ source: FileSource?) -> Bool", self.filters)

    def test_local_filter_remains_a_safety_net(self):
        # Le filtre local reste appliqué même quand le serveur a reçu
        # `types[]` : idempotent s'il a filtré, protecteur s'il ignore le
        # paramètre. La délégation sert à obtenir les bons éléments au fil de
        # la pagination, pas à se dispenser de vérifier.
        visible = self.filters[self.filters.index("nonisolated func visible("):]
        self.assertIn("case .videos: result = result.filter(\\.isVideo)", visible)
        self.assertNotIn("if !serverHandlesMedia(source) {", visible)

    def test_media_change_reloads_only_when_the_server_applies_it(self):
        rule = self.filters[self.filters.index("func requiresServerReload("):]
        rule = rule[:rule.index("\n    }")]
        self.assertIn("old.serverHandlesMedia(source) != serverHandlesMedia(source)", rule)
        self.assertIn("old.media != media", rule)
        # Un tri purement local (durée) ne déclenche aucune relecture.
        self.assertIn("if old.serverOrderBy != nil || serverOrderBy != nil { return true }", rule)

    def test_request_carries_every_requested_type(self):
        search = self.endpoints[self.endpoints.index("    static func search("):]
        search = search[:search.index("    /// Fiche complète")]
        self.assertIn('Endpoint.array("types", types)', search)
        self.assertIn("types: [String] = []", search)
        category = self.endpoints[self.endpoints.index("    static func categoryFiles("):]
        category = category[:category.index("    static func intersectionFiles(")]
        self.assertIn('Endpoint.array("types", types)', category)
        intersection = self.endpoints[self.endpoints.index("    static func intersectionFiles("):]
        intersection = intersection[:intersection.index("    /// Recherche récursive")]
        self.assertIn("types: types", intersection)

    def test_service_drops_types_for_sources_that_do_not_document_them(self):
        page = self.service[self.service.index("    func page("):self.service.index("    /// Chaque endpoint kDrive")]
        self.assertIn("let serverTypes = source.supportsServerMediaTypes ? types : []", page)
        self.assertEqual(page.count("types: serverTypes"), 3)

    def test_pagination_reuses_the_same_server_filter(self):
        more = self.model[self.model.index("    func loadMoreIfNeeded()"):self.model.index("    private func filterItemsIfNeeded(")]
        self.assertIn("let requestedTypes = mediaTypes", more)
        self.assertIn("types: requestedTypes", more)
        self.assertIn("var mediaTypes: [String] = []", self.model)

    def test_media_change_invalidates_the_cursor(self):
        reload = self.model[self.model.index("    func reload("):self.model.index("    /// Vraie quantité")]
        self.assertIn("let newTypes = sortedBy.serverHandlesMedia(source) ? (sortedBy.serverMediaTypes ?? []) : []", reload)
        self.assertIn("if orderBy != newOrderBy || order != newOrder || mediaTypes != newTypes {", reload)
        self.assertIn("orderingNeedsReload = true\n                cursor = nil\n                hasMore = false", reload)
        sync = self.model[self.model.index("    func syncSort("):self.model.index("    /// Rafraîchit en conservant")]
        self.assertIn("mediaTypes != newTypes", sync)

    def test_grid_asks_the_model_to_realign_after_a_filter_change(self):
        trigger = self.grid[self.grid.index(".onChange(of: filters)"):]
        trigger = trigger[:trigger.index(".onAppear")]
        self.assertIn("newFilters.requiresServerReload(from: oldFilters, source: viewModel.source)", trigger)
        self.assertIn("await viewModel.syncSort(with: newFilters)", trigger)

    def test_cache_keeps_server_filtered_lists_apart(self):
        key = self.cache[self.cache.index("    static func cacheKey("):self.cache.index("    /// Instantané servi")]
        self.assertIn("types: [String] = []", key)
        self.assertIn("source.supportsServerMediaTypes && !types.isEmpty", key)
        self.assertIn("t:\\(types.joined(separator: \",\"))", key)


if __name__ == "__main__":
    unittest.main()
