import Foundation

enum AppleMusicDetailArtworkLink {
    @MainActor
    static func resource(
        from item: BrowseItem,
        searchManager: SearchManager,
        allowedTypes: Set<AppleMusicFavoriteResourceType>
    ) -> AppleMusicFavoriteResource? {
        guard let resource = AppleMusicExternalLinkResolver.appleMusicResource(
            from: item,
            searchManager: searchManager
        ),
              allowedTypes.contains(resource.type) else {
            return nil
        }
        return resource
    }

    @MainActor
    static func open(
        resource: AppleMusicFavoriteResource,
        title: String,
        context: String
    ) async {
        do {
            guard let url = try await AppleMusicExternalLinkResolver.appleMusicURL(for: resource) else {
                SonosLog.debug(
                    .localService,
                    "Apple Music detail artwork lookup produced no URL context=\(context) title='\(title)' id='\(resource.id)' type='\(resource.type.rawValue)'"
                )
                return
            }
            AppleMusicExternalLinkOpener.open(
                url,
                context: "\(context) title='\(title)' id='\(resource.id)'"
            )
        } catch {
            SonosLog.error(
                .localService,
                "Apple Music detail artwork lookup failed context=\(context) title='\(title)' id='\(resource.id)' type='\(resource.type.rawValue)' error=\(error)"
            )
        }
    }
}
