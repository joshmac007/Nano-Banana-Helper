import Foundation

/// Shared constants for the application
enum Constants {
    /// Maximum number of image variations for text-to-image generation
    /// Limited to 4 to balance user experience with API rate limits and cost visibility
    static let maxTextImageVariations = 4
    
    /// Minimum number of image variations for text-to-image
    static let minTextImageVariations = 1
}
