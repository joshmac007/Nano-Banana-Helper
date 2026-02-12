import Foundation
import SwiftUI

enum AspectRatioCategory: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case square = "Square"
    case landscape = "Landscape"
    case portrait = "Portrait"
    
    var id: String { rawValue }
}

struct AspectRatio: Identifiable, Hashable, Sendable {
    let id: String // The value sent to API (e.g. "16:9") or internal identifier
    let displayName: String
    let category: AspectRatioCategory
    let width: CGFloat // For icon drawing (relative)
    let height: CGFloat // For icon drawing (relative)
    
    // API Value. "auto" for the Auto id, otherwise the id itself.
    var apiValue: String {
        return id == "Auto" ? "auto" : id
    }
    
    static let all: [AspectRatio] = [
        // Auto
        AspectRatio(id: "Auto", displayName: "Auto", category: .auto, width: 1, height: 1), // Icon can be special
        
        // Square
        AspectRatio(id: "1:1", displayName: "1:1", category: .square, width: 1, height: 1),
        
        // Landscape
        AspectRatio(id: "5:4", displayName: "5:4", category: .landscape, width: 5, height: 4),
        AspectRatio(id: "4:3", displayName: "4:3", category: .landscape, width: 4, height: 3),
        AspectRatio(id: "3:2", displayName: "3:2", category: .landscape, width: 3, height: 2),
        AspectRatio(id: "16:9", displayName: "16:9", category: .landscape, width: 16, height: 9),
        AspectRatio(id: "21:9", displayName: "21:9", category: .landscape, width: 21, height: 9),
        
        // Portrait
        AspectRatio(id: "4:5", displayName: "4:5", category: .portrait, width: 4, height: 5),
        AspectRatio(id: "3:4", displayName: "3:4", category: .portrait, width: 3, height: 4),
        AspectRatio(id: "2:3", displayName: "2:3", category: .portrait, width: 2, height: 3),
        AspectRatio(id: "9:16", displayName: "9:16", category: .portrait, width: 9, height: 16)
    ]
    
    static var `default`: AspectRatio {
        all.first(where: { $0.id == "16:9" }) ?? all[0]
    }
    
    static func from(string: String) -> AspectRatio {
        // Match by ID or apiValue, case-insensitive
        return all.first { 
            $0.id.lowercased() == string.lowercased() || 
            $0.apiValue.lowercased() == string.lowercased() 
        } ?? .default
    }
}
