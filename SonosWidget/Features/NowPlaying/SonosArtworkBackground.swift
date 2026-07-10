import SwiftUI
import UIKit

struct SonosArtworkBackground: View {
    let image: UIImage?
    let fallbackColor: Color?
    var overlayOpacity: Double = 0.6

    var body: some View {
        ZStack {
            fallbackBase

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .transition(.opacity)
                Color.black.opacity(overlayOpacity)
            }
        }
    }

    @ViewBuilder
    private var fallbackBase: some View {
        if let fallbackColor {
            LinearGradient(
                colors: [
                    fallbackColor.opacity(0.45),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.35)
        } else {
            Color.black
        }
    }
}
