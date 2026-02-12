import SwiftUI

struct AspectRatioSelector: View {
    @Binding var selectedRatio: String
    
    // Internal state to track the active category TAB
    @State private var activeCategory: AspectRatioCategory = .landscape
    @Namespace private var animationNamespace
    
    private let categories: [AspectRatioCategory] = [.auto, .square, .landscape, .portrait]
    
    // Compute current selection's category to sync tab if selection changes externally
    private var selectionCategory: AspectRatioCategory {
        AspectRatio.from(string: selectedRatio).category
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Category Tabs
            HStack(spacing: 0) {
                ForEach(categories) { category in
                    CategoryTabButton(
                        category: category,
                        isActive: activeCategory == category,
                        namespace: animationNamespace,
                        action: {
                            withAnimation(.snappy(duration: 0.25)) {
                                activeCategory = category
                            }
                        }
                    )
                }
            }
            .padding(2)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            
            // MARK: - Options Grid
            ZStack(alignment: .top) {
                if activeCategory == .auto {
                    // Special Auto State
                    AutoDescriptionView(isSelected: selectedRatio == "Auto") {
                        selectedRatio = "Auto"
                    }
                    .transition(.blurReplace)
                } else if activeCategory == .square {
                    // Square State (Usually just 1:1)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 70))], spacing: 8) {
                        let ratio = AspectRatio.from(string: "1:1")
                        RatioButton(ratio: ratio, isSelected: selectedRatio == ratio.id) {
                            withAnimation(.interactiveSpring) { selectedRatio = ratio.id }
                        }
                    }
                    .transition(.blurReplace)
                } else {
                    // Regular Grid
                    let ratios = AspectRatio.all.filter { $0.category == activeCategory && $0.id != "Auto" && $0.id != "1:1" }
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 50, maximum: 60), spacing: 8)], spacing: 8) {
                        ForEach(ratios) { ratio in
                            RatioButton(ratio: ratio, isSelected: selectedRatio == ratio.id) {
                                withAnimation(.interactiveSpring) { selectedRatio = ratio.id }
                            }
                        }
                    }
                    .transition(.blurReplace)
                }
            }
            .frame(minHeight: 60, alignment: .top) // Stable height to prevent jumping
            .animation(.snappy(duration: 0.3), value: activeCategory)
        }
        .onAppear {
            activeCategory = selectionCategory
        }
        .onChange(of: selectedRatio) { _, newValue in
            // Keep tab in sync if selection changes programmatically (e.g. History Reuse)
            let newCat = AspectRatio.from(string: newValue).category
            if activeCategory != newCat {
                withAnimation {
                    activeCategory = newCat
                }
            }
        }
    }
}

// MARK: - Subcomponents

private struct CategoryTabButton: View {
    let category: AspectRatioCategory
    let isActive: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    
    var iconName: String {
        switch category {
        case .auto: return "wand.and.stars"
        case .square: return "square"
        case .landscape: return "rectangle.ratio.16.to.9"
        case .portrait: return "rectangle.portrait"
        }
    }
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .selectedControlColor))
                        .matchedGeometryEffect(id: "TabBackground", in: namespace)
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                }
                
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? .white : .secondary)
            }
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category.rawValue)
    }
}

private struct AutoDescriptionView: View {
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? .white : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Mode")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    
                    Text("Preserves the original aspect ratio of your input images.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                    .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RatioButton: View {
    let ratio: AspectRatio
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Drawing specific ratio rect purely via Geometry
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    
                    // Fit ratio into box
                    let scale = min(w / ratio.width, h / ratio.height) * 0.75
                    let rectW = ratio.width * scale
                    let rectH = ratio.height * scale
                    
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(isSelected ? .white : .primary, lineWidth: 1.5)
                        .background(isSelected ? .white.opacity(0.2) : .clear)
                        .frame(width: rectW, height: rectH)
                        .position(x: w/2, y: h/2)
                }
                .frame(height: 28)
                
                Text(ratio.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            // Hover effect can be added via .onHover if needed, but standard button styles often handle it
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aspect Ratio \(ratio.displayName)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
