import SwiftUI

extension View {
    @ViewBuilder
    func omniGlassEffect<S: Shape>(in shape: S, prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.glassEffect(.regular.tint(.accentColor), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            if prominent {
                self
                    .background(Color.accentColor.opacity(0.22))
                    .overlay {
                        shape
                            .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                    }
                    .clipShape(shape)
            } else {
                self
                    .background(.ultraThinMaterial)
                    .clipShape(shape)
            }
        }
    }

    @ViewBuilder
    func omniBackgroundExtensionEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
    }
}
