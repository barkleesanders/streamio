import SwiftUI

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; a no-op on tvOS,
    /// where that modifier doesn't exist.
    @ViewBuilder
    func inlineNavTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
