import Foundation

/// Renders Resources/AppIcon.icns from VolumeGauge. Run via scripts/make-icon.sh.
/// With --previews <dir>, also writes sample notification images for review.
@main
enum MakeIcon {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            fputs("usage: make-icon <output.iconset> [--previews <dir>]\n", stderr)
            exit(2)
        }
        let iconset = URL(fileURLWithPath: arguments[1])
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                try write(size: points * scale, style: VolumeGauge.appIconStyle,
                          to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }

        if arguments.count == 4, arguments[2] == "--previews" {
            let folder = URL(fileURLWithPath: arguments[3])
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let samples: [(String, Float?, Bool)] = [
                ("volume-12", 0.12, false), ("volume-40", 0.40, false), ("volume-65", 0.65, false),
                ("volume-90", 0.90, false), ("volume-100", 1.0, false), ("muted", 0.4, true), ("unknown", nil, false)
            ]
            for (name, volume, muted) in samples {
                try write(size: 256, style: VolumeGauge.notificationStyle(volume: volume, muted: muted),
                          to: folder.appendingPathComponent("\(name).png"))
            }
            try write(size: 1024, style: VolumeGauge.appIconStyle, to: folder.appendingPathComponent("app-icon.png"))
        }
    }

    private static func write(size: Int, style: VolumeGauge.Style, to url: URL) throws {
        guard let image = VolumeGauge.image(size: size, style: style), VolumeGauge.writePNG(image, to: url) else {
            throw NSError(domain: "MakeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not write \(url.path)"])
        }
    }
}
