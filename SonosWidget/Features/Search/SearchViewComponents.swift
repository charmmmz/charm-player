import Observation
import SwiftUI
import UIKit
enum BrowsePullRefreshPolicy {
    static let triggerDistance = LocalLibraryPullRefreshPolicy.triggerDistance
    static let resetDistance = LocalLibraryPullRefreshPolicy.resetDistance

    static func shouldTrigger(
        pullDistance: Double,
        isRefreshing: Bool,
        hasLoaded: Bool,
        hasTriggeredInCurrentPull: Bool = false
    ) -> Bool {
        hasLoaded && !isRefreshing && !hasTriggeredInCurrentPull && pullDistance >= triggerDistance
    }

    static func shouldResetGesture(pullDistance: Double) -> Bool {
        pullDistance < resetDistance
    }

    static func indicatorOpacity(pullDistance: Double, isRefreshing: Bool) -> Double {
        LocalLibraryPullRefreshPolicy.indicatorOpacity(
            pullDistance: pullDistance,
            isRefreshing: isRefreshing
        )
    }
}
@MainActor
@Observable
final class BrowsePullRefreshController {
    private(set) var pullDistance = 0.0
    private(set) var isRefreshing = false

    @ObservationIgnored private var hasTriggeredInCurrentPull = false

    var indicatorOpacity: Double {
        BrowsePullRefreshPolicy.indicatorOpacity(
            pullDistance: pullDistance,
            isRefreshing: isRefreshing
        )
    }

    func handle(
        distance: Double,
        isExternalRefreshActive: Bool,
        hasLoaded: Bool,
        onRefresh: @escaping @MainActor () async -> Void
    ) {
        if abs(distance - pullDistance) >= 1 || distance == 0 {
            pullDistance = distance
        }

        if BrowsePullRefreshPolicy.shouldResetGesture(pullDistance: distance) {
            hasTriggeredInCurrentPull = false
        }

        guard BrowsePullRefreshPolicy.shouldTrigger(
            pullDistance: distance,
            isRefreshing: isRefreshing || isExternalRefreshActive,
            hasLoaded: hasLoaded,
            hasTriggeredInCurrentPull: hasTriggeredInCurrentPull
        ) else {
            return
        }

        trigger(onRefresh: onRefresh)
    }

    private func trigger(onRefresh: @escaping @MainActor () async -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true
        hasTriggeredInCurrentPull = true

        Task { @MainActor [weak self] in
            await onRefresh()
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isRefreshing = false
                pullDistance = 0
            }
        }
    }
}

struct BrowsePullRefreshIndicator: View {
    let controller: BrowsePullRefreshController

    var body: some View {
        let opacity = controller.indicatorOpacity

        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(.white.opacity(0.74))
            .padding(10)
            .background(.black.opacity(0.18), in: Circle())
            .opacity(opacity)
            .scaleEffect(0.86 + (0.14 * opacity))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: opacity)
            .padding(.top, 8)
    }
}

struct BrowsePullDistancePreferenceKey: PreferenceKey {
    static var defaultValue = 0.0

    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

// MARK: - Favorite grid cover

struct FavoriteCoverImageView: View {
    let itemId: String
    let imageURLString: String?
    let placeholderIcon: String

    private var resolvedURL: URL? {
        guard let s = imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s) { return u }
        return URL(string: s, encodingInvalidCharacters: true)
    }

    var body: some View {
        if let resolvedURL {
            RemoteArtworkImageView(
                url: resolvedURL,
                contentMode: .fill,
                diagnosticLabel: "favorite-cover itemID='\(itemId)'",
                failureLogPrefix: "Favorite cover artwork failed"
            ) { state in
                placeholder(for: state)
            }
        } else {
            placeholder(for: .failure)
        }
    }

    private func placeholder(for state: RemoteArtworkImagePlaceholderState) -> some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                switch state {
                case .loading:
                    ProgressView().tint(.secondary)
                case .failure:
                    Image(systemName: placeholderIcon)
                        .foregroundStyle(.tertiary)
                }
            }
    }
}
