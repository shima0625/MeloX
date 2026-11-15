import SwiftUI

/// iOS 18-compatible stand-in for the Liquid Glass surfaces the player chrome
/// used from iOS 26. A system material plus a hairline stroke keeps the
/// floating controls readable over artwork without dropping below iOS 18.
extension View {
    func meloxGlassSurface<S: InsettableShape>(
        _ shape: S,
        strokeOpacity: Double = 0.16
    ) -> some View {
        self
            .background {
                shape.fill(.ultraThinMaterial)
            }
            .overlay {
                shape.strokeBorder(
                    .white.opacity(strokeOpacity),
                    lineWidth: 0.6
                )
            }
            .clipShape(shape)
    }
}
