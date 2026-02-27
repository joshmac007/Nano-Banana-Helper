import Foundation
import CoreGraphics
import CoreImage
import ImageIO

struct RegionEditPreparation: Sendable {
    /// Pixel-space rect in top-left image coordinates.
    let cropRect: CGRect
    let croppedImageData: Data
    let croppedImageMimeType: String
    let sourcePixelSize: CGSize
}

private struct RegionEditRaster {
    let cgImage: CGImage
    let ciImage: CIImage
    let size: CGSize
}

enum RegionEditProcessorError: LocalizedError, Sendable {
    case invalidImageData
    case invalidMaskData
    case emptyMask
    case invalidCropRect
    case compositeRenderFailed
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode the source image for region editing."
        case .invalidMaskData:
            return "Could not decode the region mask."
        case .emptyMask:
            return "The selected region is empty. Paint an area before saving the edit."
        case .invalidCropRect:
            return "The selected region could not be converted into a valid crop."
        case .compositeRenderFailed:
            return "Failed to render the region-edited result."
        case .imageEncodingFailed:
            return "Failed to encode the region-edited image."
        }
    }
}

enum RegionEditProcessor {
    private static let ciContext = CIContext(options: nil)
    private static let maskThreshold: UInt8 = 8

    /// Generates a Gemini-ready crop image from the original source image and local mask.
    static func prepareCrop(
        sourceImageData: Data,
        maskImageData: Data,
        marginFraction: CGFloat = 0.18,
        minimumMarginPixels: Int = 24
    ) throws -> RegionEditPreparation {
        let source = try decodeRaster(from: sourceImageData, invalidError: .invalidImageData)
        var mask = try decodeRaster(from: maskImageData, invalidError: .invalidMaskData)

        if mask.cgImage.width != source.cgImage.width || mask.cgImage.height != source.cgImage.height {
            mask = try resize(raster: mask, to: source.size)
        }

        let maskBounds = try nonBlackBounds(in: mask.cgImage)
        let expandedRect = expandTopLeftRect(
            maskBounds,
            within: source.size,
            marginFraction: marginFraction,
            minimumMarginPixels: minimumMarginPixels
        )

        guard expandedRect.width > 0, expandedRect.height > 0 else {
            throw RegionEditProcessorError.invalidCropRect
        }

        let cropRectCI = toCICoordinates(expandedRect, imageHeight: source.size.height)
        let croppedSource = source.ciImage
            .cropped(to: cropRectCI)
            .transformed(by: CGAffineTransform(translationX: -cropRectCI.minX, y: -cropRectCI.minY))

        let cropCG = try renderCGImage(croppedSource)
        let cropPNG = try encodePNG(cropCG)

        return RegionEditPreparation(
            cropRect: expandedRect,
            croppedImageData: cropPNG,
            croppedImageMimeType: "image/png",
            sourcePixelSize: source.size
        )
    }

    /// Composites an edited crop back into the original image using the local mask with simple feathering.
    static func compositeEditedCrop(
        originalImageData: Data,
        editedCropImageData: Data,
        maskImageData: Data,
        cropRect: CGRect,
        featherRadius: CGFloat = 3
    ) throws -> (imageData: Data, mimeType: String) {
        let source = try decodeRaster(from: originalImageData, invalidError: .invalidImageData)
        var mask = try decodeRaster(from: maskImageData, invalidError: .invalidMaskData)
        var editedCrop = try decodeRaster(from: editedCropImageData, invalidError: .invalidImageData)

        if mask.cgImage.width != source.cgImage.width || mask.cgImage.height != source.cgImage.height {
            mask = try resize(raster: mask, to: source.size)
        }

        let normalizedCropRect = clampTopLeftRect(cropRect.integral, within: source.size)
        guard normalizedCropRect.width > 0, normalizedCropRect.height > 0 else {
            throw RegionEditProcessorError.invalidCropRect
        }

        let targetCropSize = normalizedCropRect.size
        if editedCrop.size != targetCropSize {
            editedCrop = try resize(raster: editedCrop, to: targetCropSize)
        }

        let cropRectCI = toCICoordinates(normalizedCropRect, imageHeight: source.size.height)

        let sourceCrop = source.ciImage
            .cropped(to: cropRectCI)
            .transformed(by: CGAffineTransform(translationX: -cropRectCI.minX, y: -cropRectCI.minY))

        let maskCrop = mask.ciImage
            .cropped(to: cropRectCI)
            .transformed(by: CGAffineTransform(translationX: -cropRectCI.minX, y: -cropRectCI.minY))

        let editedCropCI = editedCrop.ciImage
            .transformed(by: CGAffineTransform(translationX: -editedCrop.ciImage.extent.minX, y: -editedCrop.ciImage.extent.minY))

        let cropExtent = CGRect(origin: .zero, size: targetCropSize)

        var featheredMask = maskCrop
        if featherRadius > 0 {
            featheredMask = maskCrop
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius])
                .cropped(to: cropExtent)
        }

        let blendFilter = CIFilter(name: "CIBlendWithMask")
        blendFilter?.setValue(editedCropCI.cropped(to: cropExtent), forKey: kCIInputImageKey)
        blendFilter?.setValue(sourceCrop.cropped(to: cropExtent), forKey: kCIInputBackgroundImageKey)
        blendFilter?.setValue(featheredMask.cropped(to: cropExtent), forKey: kCIInputMaskImageKey)

        guard let blendedCrop = blendFilter?.outputImage?.cropped(to: cropExtent) else {
            throw RegionEditProcessorError.compositeRenderFailed
        }

        let translatedCrop = blendedCrop.transformed(
            by: CGAffineTransform(translationX: cropRectCI.minX, y: cropRectCI.minY)
        )
        let composite = translatedCrop.composited(over: source.ciImage)

        let compositeCG = try renderCGImage(composite, extent: source.ciImage.extent)
        return (try encodePNG(compositeCG), "image/png")
    }

    // MARK: - Geometry

    /// Returns bounds of painted pixels in top-left image coordinates.
    private static func nonBlackBounds(in cgImage: CGImage) throws -> CGRect {
        guard let bitmap = bitmapRGBA8(from: cgImage) else {
            throw RegionEditProcessorError.invalidMaskData
        }

        let width = bitmap.width
        let height = bitmap.height
        let bytes = bitmap.bytes
        let bytesPerRow = width * 4

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let i = rowOffset + (x * 4)
                let r = bytes[i]
                let g = bytes[i + 1]
                let b = bytes[i + 2]
                let a = bytes[i + 3]
                let intensity = max(r, max(g, b))
                if a > maskThreshold && intensity > maskThreshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            throw RegionEditProcessorError.emptyMask
        }

        return CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )
    }

    private static func expandTopLeftRect(
        _ rect: CGRect,
        within imageSize: CGSize,
        marginFraction: CGFloat,
        minimumMarginPixels: Int
    ) -> CGRect {
        let marginX = max(CGFloat(minimumMarginPixels), rect.width * marginFraction)
        let marginY = max(CGFloat(minimumMarginPixels), rect.height * marginFraction)

        let expanded = CGRect(
            x: rect.minX - marginX,
            y: rect.minY - marginY,
            width: rect.width + (marginX * 2),
            height: rect.height + (marginY * 2)
        )
        return clampTopLeftRect(expanded.integral, within: imageSize)
    }

    private static func clampTopLeftRect(_ rect: CGRect, within imageSize: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: imageSize)
        return rect.intersection(bounds)
    }

    /// Converts a top-left pixel rect to Core Image's bottom-left coordinate space.
    private static func toCICoordinates(_ topLeftRect: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(
            x: topLeftRect.minX,
            y: imageHeight - topLeftRect.maxY,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
    }

    // MARK: - Raster Helpers

    private static func decodeRaster(from data: Data, invalidError: RegionEditProcessorError) throws -> RegionEditRaster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw invalidError
        }

        let ciImage = CIImage(cgImage: cgImage)
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return RegionEditRaster(cgImage: cgImage, ciImage: ciImage, size: size)
    }

    private static func resize(raster: RegionEditRaster, to size: CGSize) throws -> RegionEditRaster {
        guard size.width > 0, size.height > 0 else {
            throw RegionEditProcessorError.invalidCropRect
        }

        let base = raster.ciImage.transformed(
            by: CGAffineTransform(translationX: -raster.ciImage.extent.minX, y: -raster.ciImage.extent.minY)
        )
        let scaleX = size.width / max(1, raster.ciImage.extent.width)
        let scaleY = size.height / max(1, raster.ciImage.extent.height)
        let resized = base
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: size))

        let resizedCG = try renderCGImage(resized)
        return RegionEditRaster(cgImage: resizedCG, ciImage: CIImage(cgImage: resizedCG), size: size)
    }

    private static func renderCGImage(_ image: CIImage, extent: CGRect? = nil) throws -> CGImage {
        let renderExtent = extent ?? image.extent
        guard let cgImage = ciContext.createCGImage(image, from: renderExtent) else {
            throw RegionEditProcessorError.compositeRenderFailed
        }
        return cgImage
    }

    private static func encodePNG(_ cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw RegionEditProcessorError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RegionEditProcessorError.imageEncodingFailed
        }
        return data as Data
    }

    private static func bitmapRGBA8(from cgImage: CGImage) -> (width: Int, height: Int, bytes: [UInt8])? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let didDraw = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }

            // Flip so byte rows are top-to-bottom, matching the editor's mask coordinate convention.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard didDraw else { return nil }
        return (width, height, bytes)
    }
}
