import UIKit
import AVFoundation
import ImageIO
import ModCore

public final class ModBannerView: UIView {
    private let imageView = UIImageView()
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var banner: ModBanner?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
        self.imageView.contentMode = .scaleAspectFill
        self.addSubview(self.imageView)
        self.playerLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.playerLayer)
    }

    required init?(coder: NSCoder) { return nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.imageView.frame = self.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.playerLayer.frame = self.bounds
        CATransaction.commit()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil {
            self.player?.pause()
        } else {
            self.player?.play()
        }
    }

    public func update(banner: ModBanner, opacity: Int) {
        self.alpha = CGFloat(opacity) / 100
        guard self.banner != banner else { return }
        self.banner = banner
        self.player?.pause()
        self.playerLayer.player = nil
        self.looper = nil
        self.player = nil
        self.imageView.image = nil

        guard let url = ModSettings.shared.bannerURL(banner) else { return }
        if banner.kind == .video {
            let player = AVQueuePlayer()
            player.isMuted = true
            self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player
            self.playerLayer.player = player
            if self.window != nil { player.play() }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = Self.loadImage(at: url, animated: banner.kind == .gif)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.banner == banner else { return }
                    self.imageView.image = image
                }
            }
        }
    }

    private static func loadImage(at url: URL, animated: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: animated ? 480 : 1280,
        ]
        let sourceCount = CGImageSourceGetCount(source)
        let stride = animated ? max(1, (sourceCount + 59) / 60) : 1
        let limit = animated ? sourceCount : min(sourceCount, 1)
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for index in 0 ..< limit {
            if animated {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                duration += max(0.02, delay)
            }
            if index % stride == 0, let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                frames.append(UIImage(cgImage: frame))
            }
        }
        if frames.count > 1 { return UIImage.animatedImage(with: frames, duration: duration) }
        return frames.first
    }
}
