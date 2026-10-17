import Foundation

@main
struct AdaptiveLayoutChecks {
    static func main() {
        for width: CGFloat in [320, 375, 430, 700, 1024, 1366] {
            for pad in [false, true] {
                for accessible in [false, true] {
                    let layout = IPadLayout(isPad: pad, width: width, largeText: accessible)
                    for preference in 2...7 {
                        let count = layout.fileColumns(preferred: preference, margin: 14, spacing: 10)
                        let card = (width - layout.horizontalInset(base: 14) * 2 - CGFloat(count - 1) * 10) / CGFloat(count)
                        assert(count >= 1 && count <= 12)
                        assert(card >= (accessible ? 220 : 100) || count == 1)
                    }
                }
            }
        }
        let pad = IPadLayout(isPad: true, width: 1366)
        let counts = (2...7).map { pad.fileColumns(preferred: $0, margin: 14, spacing: 10) }
        assert(Set(counts).count == counts.count, "Every iPad density must have a visible effect")
        assert(IPadLayout(isPad: false, width: 375, largeText: true).fileColumns(preferred: 7, margin: 14, spacing: 10) == 1)
        for width: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            let count = IPadLayout(isPad: true, width: width).fileColumns(preferred: 7, margin: 14, spacing: 10)
            assert((1...12).contains(count))
        }
        print("Adaptive layout checks passed")
    }
}
