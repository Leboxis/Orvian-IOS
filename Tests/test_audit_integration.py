"""Integration wiring checks; behavioral Swift checks run on the macOS CI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AuditIntegrationChecks(unittest.TestCase):
    def source(self, path):
        return (ROOT / path).read_text()

    def test_publication_requires_originating_credential(self):
        center = self.source('Orvian/Features/Shared/FileGridMutationCenter.swift')
        self.assertIn('func publish(_ mutation: FileGridMutation, credentialFingerprint: String?)', center)
        self.assertIn('credentialFingerprint == TokenStore.credentialFingerprint()', center)

    def test_restore_is_broadcast(self):
        vm = self.source('Orvian/Features/Shared/FileGridViewModel.swift')
        self.assertIn('.restored(driveId: driveId, fileIds:', vm)

    def test_page_is_published_before_count_finishes(self):
        vm = self.source('Orvian/Features/Shared/FileGridViewModel.swift')
        reload = vm[vm.index('    func reload('):vm.index('    private func fetchDirectoryCount')]
        self.assertLess(reload.index('items = filterItemsIfNeeded'), reload.index('await countTask'))

    def test_recent_preservation_uses_confirmed_uploads(self):
        recent = self.source('Orvian/Core/Cache/RecentUploadsLoader.swift')
        self.assertIn('pendingLocalUploads', recent)
        self.assertNotIn('now - ts', recent)

    def test_all_upload_jobs_share_permits(self):
        manager = self.source('Orvian/Core/Upload/UploadManager.swift')
        self.assertIn('private let uploadPermits = AsyncPermitPool(capacity: 4)', manager)
        self.assertEqual(manager.count('try await self.uploadPermits.acquire()'), 3)

    def test_publication_is_serialized(self):
        workflow = self.source('.github/workflows/build.yml')
        self.assertIn("'orvian-publish-main'", workflow)
        self.assertIn('cancel-in-progress: false', workflow)
        self.assertIn('Skip outdated publication', workflow)

    def test_privacy_test_workflow_is_not_added(self):
        workflow = self.source('.github/workflows/build.yml')
        self.assertNotIn('xcodebuild test', workflow)


if __name__ == '__main__':
    unittest.main()
