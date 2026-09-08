import SwiftUI
import UIKit

/// Core Animation respecte le délai de chaque frame et conserve les gestes SwiftUI.
struct AnimatedGIFView: UIViewRepresentable {
    let image: GIFImage
    let isPlaying: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.contentsGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard isPlaying, image.frames.count > 1 else {
            view.layer.removeAnimation(forKey: "gif")
            view.layer.contents = image.frames.first
            return
        }
        guard view.layer.animation(forKey: "gif") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        var elapsed = 0.0
        var times: [NSNumber] = []
        for delay in image.delays {
            times.append(NSNumber(value: elapsed / image.duration))
            elapsed += delay
        }
        times.append(1)
        animation.values = image.frames + [image.frames[image.frames.count - 1]]
        animation.keyTimes = times
        animation.duration = image.duration
        animation.calculationMode = .discrete
        animation.repeatCount = image.loopCount == 0 ? .infinity : Float(image.loopCount)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        view.layer.contents = image.frames.first
        view.layer.add(animation, forKey: "gif")
    }

    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        view.layer.removeAnimation(forKey: "gif")
        view.layer.contents = nil
    }
}
