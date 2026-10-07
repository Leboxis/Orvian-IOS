"""Exercise actual random-view/cache methods and upload cleanup (macOS Swift)."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


def fixtures():
    common = '''import Foundation
struct DriveFile: Equatable { let id: Int; var isDirectory = false }
struct FileFilters: Equatable { var revision = 0 }
enum FileSource: Equatable {
    case directory, search
    var isServerFiltered: Bool { self == .search }
}
final class FileGridViewModel {
    var source = FileSource.directory
    var itemsRevision = 0
    var items: [DriveFile] = []
}
final class ViewerRouter {
    var opened: DriveFile?
    var siblings: [DriveFile] = []
    func open(_ file: DriveFile, siblings: [DriveFile], filters: FileFilters,
              searchText: String, viewModel: FileGridViewModel) {
        opened = file; self.siblings = siblings
    }
}
'''
    classes = []
    for name, path in [
        ('FavoritesFixture', 'Orvian/Features/Favorites/FavoritesView.swift'),
        ('DirectoryFixture', 'Orvian/Features/Home/DirectoryView.swift'),
    ]:
        source = (ROOT / path).read_text(encoding='utf-8')
        assert '.disabled(playableFiles.isEmpty)' in source
        population = block(source, '    private var playableFiles:')
        assert 'visibleSelectionItems.filter' in population
        members = [block(source, marker) for marker in [
            '    private struct VisibleItemsContext:', '    private struct VisibleItemsReport',
            '    private var currentVisibleItemsContext:', '    private var visibleSelectionItems:',
            '    private var playableFiles:', '    private func openRandomFile()',
        ]]
        classes.append('final class ' + name + ''' {
    var viewModel = FileGridViewModel()
    var activeViewModel: FileGridViewModel { viewModel }
    var filters = FileFilters()
    var searchText = ""
    var searchFocused = true
    let router = ViewerRouter()
    private var visibleItemsReport: VisibleItemsReport?
''' + '\n'.join(members) + '''
    func check() {
        let image = DriveFile(id: 1)
        let hiddenText = DriveFile(id: 2)
        let folder = DriveFile(id: 3, isDirectory: true)
        viewModel.items = [image, hiddenText, folder]
        visibleItemsReport = VisibleItemsReport(context: currentVisibleItemsContext, items: [image, folder])
        for _ in 0..<50 {
            openRandomFile()
            precondition(router.opened == image)
            precondition(router.siblings == [image])
        }
        // A changed filter/search/list invalidates the old visible report.
        filters.revision += 1
        router.opened = nil
        openRandomFile()
        precondition(router.opened == nil)
        visibleItemsReport = VisibleItemsReport(context: currentVisibleItemsContext, items: [folder])
        openRandomFile()
        precondition(router.opened == nil)
        searchText = "missing"
        visibleItemsReport = VisibleItemsReport(context: currentVisibleItemsContext, items: [])
        openRandomFile()
        precondition(router.opened == nil)
        searchText = "changed"
        openRandomFile()
        precondition(router.opened == nil)
    }
}
''')
    api = (ROOT / 'Orvian/Core/API/APIClient.swift').read_text(encoding='utf-8')
    cache = 'enum CacheFixture {\n' + '\n'.join(block(api, marker) for marker in [
        '    static func currentCacheLimitMB()', '    private static func currentCacheLimitBytes()',
    ]) + '''
    static func check() {
        let key = "networkCacheLimitMB"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        precondition(currentCacheLimitBytes() == 100 * 1024 * 1024)
        for mb in [0, 25, 50, 100, 250] {
            UserDefaults.standard.set(mb, forKey: key)
            precondition(currentCacheLimitBytes() == mb * 1024 * 1024)
        }
    }
}
'''
    return common + '\n'.join(classes) + cache + '''
@main struct RequestedChecks {
    static func main() {
        FavoritesFixture().check()
        DirectoryFixture().check()
        CacheFixture.check()
        print("Random visible files and network cache checks passed")
    }
}
'''


def main():
    generated = fixtures()
    if '--check-source' in sys.argv:
        print('Requested regression source extraction passed')
        return
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        fixture = root / 'RequestedFixtures.swift'
        fixture.write_text(generated, encoding='utf-8')
        for name, paths in [
            ('requested', [fixture]),
            ('upload-cleanup', [ROOT / 'Orvian/Core/Utils/UploadSessionCleanup.swift',
                                ROOT / 'Tests/UploadSessionCleanupChecks.swift']),
        ]:
            executable = root / name
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5',
                            *map(str, paths), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True, timeout=60)


if __name__ == '__main__':
    main()
