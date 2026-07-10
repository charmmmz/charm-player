import Foundation
import UIKit

@MainActor
enum AppleMusicExternalLinkOpener {
    static func open(_ url: URL, context: String) {
        let urlString = url.absoluteString
        SonosLog.info(
            .localService,
            "Apple Music external open start context=\(context) url='\(urlString)'"
        )
        UIApplication.shared.open(url, options: [:]) { success in
            SonosLog.info(
                .localService,
                "Apple Music external open complete context=\(context) success=\(success) url='\(urlString)'"
            )
        }
    }
}
