import SwiftUI
import AppKit
import ImageIO

// MARK: - Visual Effect View (macOS Blur)
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Cost Estimator
struct CostEstimatorView: View {
    let modelName: String
    let stagedInputCount: Int
    let generationCount: Int
    let inputCount: Int
    let outputCount: Int
    let imageSize: String
    let isBatchTier: Bool
    let isMultiInput: Bool

    private var estimate: CostEstimate {
        PricingEngine.estimate(
            modelName: modelName,
            imageSize: imageSize,
            isBatchTier: isBatchTier,
            inputCount: inputCount,
            outputCount: outputCount
        )
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                if stagedInputCount == 0 {
                    Text("\(generationCount) generated output\(generationCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                } else if isMultiInput {
                    Text("\(stagedInputCount) inputs x \(generationCount) generation\(generationCount == 1 ? "" : "s") -> \(outputCount) output\(outputCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                } else {
                    Text("\(stagedInputCount) inputs x \(generationCount) generation\(generationCount == 1 ? "" : "s") -> \(outputCount) output\(outputCount == 1 ? "" : "s") @ \(imageSize)")
                        .font(.subheadline)
                }
                Text(ModelCatalog.displayName(for: modelName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if estimate.inputCost > 0 {
                    let inputRate = estimate.inputCost / Double(max(1, estimate.inputCount))
                    let outputRate = estimate.outputCost / Double(max(1, estimate.outputCount))
                    Text("$\(inputRate, specifier: "%.4f")/input + $\(outputRate, specifier: "%.4f")/output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let outputRate = estimate.outputCost / Double(max(1, estimate.outputCount))
                    Text("$\(outputRate, specifier: "%.4f")/output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("≈ $\(estimate.total, specifier: "%.2f")")
                .font(.headline)
                .foregroundStyle(.green)
        }
    }
}

enum PreviewImageLoader {
    enum SecurityScopedFileAccess {
        nonisolated static func withAccessibleURL<T>(
            path: String,
            bookmark: Data? = nil,
            directoryBookmark: Data? = nil,
            directoryPath: String? = nil,
            pathing: any SecurityScopedPathing = LiveSecurityScopedPathing(),
            _ body: (URL) throws -> T
        ) rethrows -> T? {
            let fileURL = URL(fileURLWithPath: path)

            if pathing.requiresSecurityScope(path: path) == false {
                return try body(fileURL)
            }

            if let bookmark,
               let value = try pathing.withResolvedBookmark(bookmark, body) {
                return value
            }

            if let directoryBookmark,
               let directoryPath,
               let relativePath = relativePathIfContained(path: path, directoryPath: directoryPath),
               let value = try pathing.withResolvedBookmark(directoryBookmark, { scopedDirectoryURL in
                   let scopedFileURL = relativePath.isEmpty
                       ? scopedDirectoryURL
                       : scopedDirectoryURL.appendingPathComponent(relativePath)
                   return try body(scopedFileURL)
               }) {
                return value
            }

            return try body(fileURL)
        }

        nonisolated private static func relativePathIfContained(path: String, directoryPath: String) -> String? {
            let normalizedFilePath = URL(fileURLWithPath: path).standardizedFileURL.path
            let normalizedDirectoryPath = URL(fileURLWithPath: directoryPath).standardizedFileURL.path

            guard
                normalizedFilePath == normalizedDirectoryPath ||
                normalizedFilePath.hasPrefix(normalizedDirectoryPath + "/")
            else {
                return nil
            }

            if normalizedFilePath == normalizedDirectoryPath {
                return ""
            }

            return String(normalizedFilePath.dropFirst(normalizedDirectoryPath.count + 1))
        }
    }

    nonisolated static func loadImage(
        path: String,
        bookmark: Data? = nil,
        directoryBookmark: Data? = nil,
        directoryPath: String? = nil,
        maxPixelSize: CGFloat? = nil,
        pathing: any SecurityScopedPathing = LiveSecurityScopedPathing()
    ) -> NSImage? {
        SecurityScopedFileAccess.withAccessibleURL(
            path: path,
            bookmark: bookmark,
            directoryBookmark: directoryBookmark,
            directoryPath: directoryPath,
            pathing: pathing
        ) { accessibleURL in
            loadImage(at: accessibleURL, maxPixelSize: maxPixelSize)
        } ?? nil
    }

    nonisolated private static func loadImage(at url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        guard let maxPixelSize, maxPixelSize > 0 else {
            return NSImage(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: image, size: .zero)
    }
}
