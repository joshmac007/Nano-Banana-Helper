import Foundation

/// Shared constants for the application
enum Constants {
    /// Maximum number of output variations supported by the UI.
    /// Limited to 4 to balance user experience with API rate limits and cost visibility.
    static let maxTextImageVariations = 4
    
    /// Minimum number of output variations supported by the UI.
    static let minTextImageVariations = 1
}
