import Foundation

@main
enum DriveLayoutChecks {
    static func main() {
        // Un changement iPad ne doit pas modifier les préférences iPhone.
        for width: CGFloat in [320, 440, 1_368] {
            let phone = DriveLayout(isPad: false, width: width)
            assert(phone.fileColumns(preferred: 3) == 3)
            assert(phone.fileColumns(preferred: 7) == 7)
            assert(phone.fileColumns(preferred: 0) == 2)
            assert(phone.fileColumns(preferred: 99) == 7)
            assert(phone.tagColumns(preferred: 2) == 2)
            assert(phone.tagColumns(preferred: 3) == 3)
            assert(!phone.usesTwoColumns)
        }

        let withSidebar = DriveLayout(isPad: true, width: 1_000)
        let withoutSidebar = DriveLayout(isPad: true, width: 1_260)
        assert(withSidebar.fileColumns(preferred: 3) == 5)
        assert(withoutSidebar.fileColumns(preferred: 3) == 7)
        assert(withSidebar.tagColumns(preferred: 2) == 3)
        assert(withoutSidebar.tagColumns(preferred: 2) == 4)
        assert(withSidebar.fileColumns(preferred: 7) == 8)
        assert(withSidebar.usesTwoColumns)

        let narrow = DriveLayout(isPad: true, width: 320)
        assert(narrow.fileColumns(preferred: 3) == 1)
        assert(narrow.tagColumns(preferred: 2) == 1)
        assert(!narrow.usesTwoColumns)
        assert(DriveLayout(isPad: true, width: 0).fileColumns(preferred: 3) == 1)
        assert(!DriveLayout(isPad: true, width: 799).usesTwoColumns)
        assert(DriveLayout(isPad: true, width: 800).usesTwoColumns)
        print("Drive layout checks passed")
    }
}
