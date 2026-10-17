import Foundation

@main struct BrowserPreferencesChecks {
    static func main() {
        let defaults = UserDefaults(suiteName: "Orvian-test-\(UUID())")!
        for old in [-4, 0, 2, 3, 4, 7, 99] {
            defaults.removeObject(forKey: "phoneFileGridColumns")
            defaults.removeObject(forKey: "padFileGridDensity")
            defaults.set(old, forKey: "fileGridColumns")
            BrowserPreferences.migrate(defaults)
            assert(defaults.integer(forKey: "phoneFileGridColumns") == min(3, max(2, old)))
            assert(defaults.integer(forKey: "padFileGridDensity") == min(7, max(2, old)))
            defaults.set(2, forKey: "phoneFileGridColumns")
            BrowserPreferences.migrate(defaults)
            assert(defaults.integer(forKey: "phoneFileGridColumns") == 2)
        }
        assert(Set(FileBrowserScope.allCases.map(\.presentationKey)).count == 3)
        defaults.set(FilePresentation.list.rawValue, forKey: FileBrowserScope.home.presentationKey)
        defaults.set(FilePresentation.grid.rawValue, forKey: FileBrowserScope.favorites.presentationKey)
        defaults.set(FilePresentation.list.rawValue, forKey: FileBrowserScope.tag.presentationKey)
        BrowserPreferences.migrate(defaults)
        assert(defaults.string(forKey: FileBrowserScope.home.presentationKey) == "list")
        assert(defaults.string(forKey: FileBrowserScope.favorites.presentationKey) == "grid")
        assert(defaults.string(forKey: FileBrowserScope.tag.presentationKey) == "list")
        print("Browser preference migration checks passed")
    }
}
