import UIKit
import UniformTypeIdentifiers
import UserNotifications

private struct SharePlaybackSnapshot: Sendable {
    let status: ShareSpeakerPlaybackStatus?
    let nowPlaying: ShareSpeakerNowPlaying?
}

final class ShareViewController: UIViewController {
    private let resolver = ShareAppleMusicResolver()
    private let playbackService = ShareSonosPlaybackService()

    private var shareURLString: String?
    private var playable: ShareAppleMusicPlayable?
    private var speakerGroups: [ShareSpeakerGroup] = []
    private var speakerStatuses: [String: ShareSpeakerPlaybackStatus] = [:]
    private var speakerNowPlaying: [String: ShareSpeakerNowPlaying] = [:]
    private var speakerArtworkURLs: [String: String] = [:]
    private var speakerArtworkImages: [String: UIImage] = [:]
    private var selectedGroupID: String?
    private var successfulGroupID: String?
    private var isPlaying = false
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?

    private let gradientLayer = CAGradientLayer()
    private let artworkImageView = UIImageView()
    private let artworkFallbackView = UIImageView(image: UIImage(systemName: "music.note"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statusLabel = UILabel()
    private let statusIconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let speakerStack = UIStackView()
    private let emptyStateLabel = UILabel()
    private let notifyButton = UIButton(type: .system)
    private var speakerCards: [String: SpeakerGroupCard] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: 560)
        configureView()
        processSharedInput()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    deinit {
        loadTask?.cancel()
        playTask?.cancel()
        statusTask?.cancel()
        artworkTask?.cancel()
    }

    private func configureView() {
        gradientLayer.colors = [
            UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor,
            UIColor(red: 0.11, green: 0.05, blue: 0.09, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0, 0.45, 1]
        view.layer.insertSublayer(gradientLayer, at: 0)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)

        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 12

        let artworkContainer = UIView()
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        artworkContainer.layer.cornerRadius = 8
        artworkContainer.clipsToBounds = true

        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkImageView.isHidden = true

        artworkFallbackView.translatesAutoresizingMaskIntoConstraints = false
        artworkFallbackView.tintColor = UIColor(red: 1.0, green: 0.22, blue: 0.47, alpha: 1)
        artworkFallbackView.contentMode = .scaleAspectFit

        artworkContainer.addSubview(artworkImageView)
        artworkContainer.addSubview(artworkFallbackView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.text = "Apple Music ready"

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitleLabel.numberOfLines = 2
        subtitleLabel.text = "Choose a speaker to start playback."

        headerStack.addArrangedSubview(artworkContainer)
        headerStack.addArrangedSubview(textStack)

        let statusIndicatorContainer = UIView()
        statusIndicatorContainer.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = UIStackView(arrangedSubviews: [statusIndicatorContainer, statusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusIndicatorContainer.addSubview(spinner)
        statusIndicatorContainer.addSubview(statusIconView)

        spinner.color = UIColor.white.withAlphaComponent(0.75)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()

        statusIconView.tintColor = UIColor(red: 0.52, green: 1.0, blue: 0.68, alpha: 1)
        statusIconView.contentMode = .scaleAspectFit
        statusIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.isHidden = true

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        statusLabel.numberOfLines = 2
        statusLabel.text = "Reading Apple Music share..."
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.delaysContentTouches = false

        speakerStack.axis = .vertical
        speakerStack.spacing = 10
        speakerStack.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyStateLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.text = "No speakers yet. Open Charm Player once on this Wi-Fi."
        emptyStateLabel.isHidden = true

        scrollView.addSubview(speakerStack)

        notifyButton.setTitle("Notify to open Charm Player", for: .normal)
        notifyButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        notifyButton.tintColor = UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
        notifyButton.addTarget(self, action: #selector(notifyButtonTapped), for: .touchUpInside)
        notifyButton.isHidden = true

        let mainStack = UIStackView(arrangedSubviews: [
            headerStack,
            statusRow,
            scrollView,
            emptyStateLabel,
            notifyButton
        ])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        let scrollFitsContentConstraint = scrollView.heightAnchor.constraint(equalTo: speakerStack.heightAnchor)
        scrollFitsContentConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            mainStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor, constant: -4),
            mainStack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 8),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -8),

            artworkContainer.widthAnchor.constraint(equalToConstant: 64),
            artworkContainer.heightAnchor.constraint(equalToConstant: 64),
            artworkImageView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkImageView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            artworkFallbackView.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            artworkFallbackView.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            artworkFallbackView.widthAnchor.constraint(equalToConstant: 26),
            artworkFallbackView.heightAnchor.constraint(equalToConstant: 26),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: ShareStatusIndicatorLayout.rowMinimumHeight),
            statusIndicatorContainer.widthAnchor.constraint(equalToConstant: ShareStatusIndicatorLayout.indicatorSlotSize.width),
            statusIndicatorContainer.heightAnchor.constraint(equalToConstant: ShareStatusIndicatorLayout.indicatorSlotSize.height),
            spinner.centerXAnchor.constraint(equalTo: statusIndicatorContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: statusIndicatorContainer.centerYAnchor),
            statusIconView.centerXAnchor.constraint(equalTo: statusIndicatorContainer.centerXAnchor),
            statusIconView.centerYAnchor.constraint(equalTo: statusIndicatorContainer.centerYAnchor),
            statusIconView.widthAnchor.constraint(equalToConstant: 18),
            statusIconView.heightAnchor.constraint(equalToConstant: 18),

            speakerStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            speakerStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            speakerStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            speakerStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            speakerStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            scrollFitsContentConstraint,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 310)
        ])
    }

    private func processSharedInput() {
        loadFirstSharedValue { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let value):
                    self.prepareShare(value)
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func prepareShare(_ value: String) {
        do {
            let urlString = try AppleMusicShareExtensionStore.saveFirstAppleMusicURL(from: value)
            shareURLString = urlString
            speakerGroups = AppleMusicShareExtensionStore.cachedSpeakerGroups
            updateSpeakerCards()
            refreshPlaybackStatuses(for: speakerGroups)
            setStatus("Choose a speaker to start playback.", loading: false)

            loadTask = Task { [weak self] in
                guard let self else { return }
                async let resolvedPlayable = self.resolver.resolve(urlString: urlString)
                async let refreshedGroups = AppleMusicShareExtensionStore.refreshedSpeakerGroups()

                if let playable = try? await resolvedPlayable {
                    await MainActor.run {
                        self.playable = playable
                        self.updatePlayable(playable)
                    }
                }

                let groups = await refreshedGroups
                await MainActor.run {
                    self.speakerGroups = groups
                    self.speakerStatuses = self.speakerStatuses.filter { key, _ in
                        groups.contains(where: { $0.id == key })
                    }
                    self.speakerNowPlaying = self.speakerNowPlaying.filter { key, _ in
                        groups.contains(where: { $0.id == key })
                    }
                    self.speakerArtworkURLs = self.speakerArtworkURLs.filter { key, _ in
                        groups.contains(where: { $0.id == key })
                    }
                    self.speakerArtworkImages = self.speakerArtworkImages.filter { key, _ in
                        groups.contains(where: { $0.id == key })
                    }
                    self.updateSpeakerCards()
                    self.refreshPlaybackStatuses(for: groups)
                    if groups.isEmpty {
                        self.setStatus("Open Charm Player once on this Wi-Fi, then share again.", loading: false)
                        self.notifyButton.isHidden = false
                    }
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func updatePlayable(_ playable: ShareAppleMusicPlayable) {
        titleLabel.text = playable.title
        let parts = [playable.artist, playable.album]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        subtitleLabel.text = parts.isEmpty ? "Apple Music" : parts.joined(separator: " - ")
        loadArtwork(from: playable.artworkURLString)
    }

    private func updateSpeakerCards() {
        speakerCards.values.forEach { $0.removeFromSuperview() }
        speakerCards.removeAll()

        emptyStateLabel.isHidden = !speakerGroups.isEmpty
        for group in speakerGroups {
            let card = SpeakerGroupCard()
            card.configure(
                group: group,
                status: speakerStatuses[group.id],
                nowPlaying: speakerNowPlaying[group.id],
                artworkImage: speakerArtworkImages[group.id],
                isSelected: selectedGroupID == group.id,
                isLoading: isPlaying && selectedGroupID == group.id,
                isSuccessful: successfulGroupID == group.id
            )
            card.addAction(UIAction { [weak self] _ in
                self?.startPlayback(on: group)
            }, for: .touchUpInside)
            speakerCards[group.id] = card
            speakerStack.addArrangedSubview(card)
        }
    }

    private func refreshPlaybackStatuses(for groups: [ShareSpeakerGroup]) {
        statusTask?.cancel()
        guard !groups.isEmpty else {
            speakerStatuses.removeAll()
            speakerNowPlaying.removeAll()
            speakerArtworkURLs.removeAll()
            speakerArtworkImages.removeAll()
            artworkTask?.cancel()
            updateSpeakerCards()
            return
        }

        statusTask = Task { [weak self] in
            var statuses: [String: ShareSpeakerPlaybackStatus] = [:]
            var nowPlayingByGroup: [String: ShareSpeakerNowPlaying] = [:]
            await withTaskGroup(
                of: (String, ShareSpeakerPlaybackStatus?, ShareSpeakerNowPlaying?).self
            ) { taskGroup in
                for group in groups {
                    taskGroup.addTask {
                        let snapshot = await Self.playbackSnapshot(
                            for: group.coordinator.playbackIP,
                            timeoutMilliseconds: 1_600
                        )
                        return (group.id, snapshot?.status, snapshot?.nowPlaying)
                    }
                }

                for await (groupID, status, nowPlaying) in taskGroup {
                    if let status {
                        statuses[groupID] = status
                    }
                    if let nowPlaying {
                        nowPlayingByGroup[groupID] = nowPlaying
                    }
                }
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.speakerStatuses = statuses
                self.speakerNowPlaying = nowPlayingByGroup
                self.updateSpeakerCards()
                self.refreshSpeakerArtwork(for: nowPlayingByGroup)
            }
        }
    }

    private static func playbackSnapshot(
        for ip: String,
        timeoutMilliseconds: UInt64
    ) async -> SharePlaybackSnapshot? {
        await withTaskGroup(of: SharePlaybackSnapshot?.self) { taskGroup in
            taskGroup.addTask {
                async let status: ShareSpeakerPlaybackStatus? = try? ShareSonosAPI.getTransportInfo(ip: ip)
                async let nowPlaying: ShareSpeakerNowPlaying? = try? ShareSonosAPI.getPositionInfo(ip: ip)
                return await SharePlaybackSnapshot(status: status, nowPlaying: nowPlaying)
            }
            taskGroup.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return nil
            }

            let result = await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return result
        }
    }

    private func refreshSpeakerArtwork(for nowPlayingByGroup: [String: ShareSpeakerNowPlaying]) {
        artworkTask?.cancel()

        let nextURLs = nowPlayingByGroup.compactMapValues(\.albumArtURLString)
        let previousURLs = speakerArtworkURLs
        speakerArtworkURLs = nextURLs
        speakerArtworkImages = speakerArtworkImages.filter { groupID, _ in
            previousURLs[groupID] == nextURLs[groupID]
        }
        updateSpeakerCards()

        let missingURLs = nextURLs.filter { groupID, _ in
            speakerArtworkImages[groupID] == nil
        }
        guard !missingURLs.isEmpty else {
            return
        }

        artworkTask = Task { [weak self] in
            var imageDataByGroup: [String: Data] = [:]
            await withTaskGroup(of: (String, Data?).self) { taskGroup in
                for (groupID, urlString) in missingURLs {
                    taskGroup.addTask {
                        let data = await Self.albumArtworkData(
                            from: urlString,
                            timeoutMilliseconds: ShareSpeakerArtworkLoadPolicy.requestTimeoutMilliseconds,
                            maxAttempts: ShareSpeakerArtworkLoadPolicy.maxAttempts
                        )
                        return (groupID, data)
                    }
                }

                for await (groupID, data) in taskGroup {
                    if let data {
                        imageDataByGroup[groupID] = data
                    }
                }
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                for (groupID, data) in imageDataByGroup {
                    guard self.speakerArtworkURLs[groupID] == missingURLs[groupID],
                          let image = UIImage(data: data) else {
                        continue
                    }
                    self.speakerArtworkImages[groupID] = image
                }
                self.updateSpeakerCards()
            }
        }
    }

    private static func albumArtworkData(
        from urlString: String,
        timeoutMilliseconds: UInt64,
        maxAttempts: Int
    ) async -> Data? {
        let attempts = max(maxAttempts, 1)
        for _ in 0..<attempts {
            if let data = await albumArtworkDataAttempt(
                from: urlString,
                timeoutMilliseconds: timeoutMilliseconds
            ) {
                return data
            }
        }
        return nil
    }

    private static func albumArtworkDataAttempt(
        from urlString: String,
        timeoutMilliseconds: UInt64
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { taskGroup in
            taskGroup.addTask {
                guard let url = URL(string: urlString) else { return nil }
                var request = URLRequest(
                    url: url,
                    timeoutInterval: Double(timeoutMilliseconds) / 1_000
                )
                request.cachePolicy = .returnCacheDataElseLoad
                guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                    return nil
                }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode) {
                    return nil
                }
                return data
            }
            taskGroup.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                return nil
            }

            let result = await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return result
        }
    }

    private func startPlayback(on group: ShareSpeakerGroup) {
        guard !isPlaying else { return }
        guard let urlString = shareURLString else {
            showError(SharePlaybackError.missingAppleMusicLink.localizedDescription)
            return
        }
        guard let credential = AppleMusicShareExtensionStore.appleMusicCredential else {
            showError(SharePlaybackError.missingCredential.localizedDescription)
            notifyButton.isHidden = false
            return
        }

        selectedGroupID = group.id
        successfulGroupID = nil
        isPlaying = true
        updateSpeakerCards()
        setStatus("Starting on \(group.displayName)...", loading: true)

        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved: ShareAppleMusicPlayable
                if let playable = self.playable {
                    resolved = playable
                } else {
                    resolved = try await self.resolver.resolve(urlString: urlString)
                }
                await MainActor.run {
                    self.playable = resolved
                    self.updatePlayable(resolved)
                }

                try await self.playbackService.play(
                    resolved,
                    on: group,
                    credential: credential
                )

                AppleMusicShareExtensionStore.clearPendingAppleMusicShare()
                await MainActor.run {
                    self.isPlaying = false
                    self.markSuccess(on: group)
                }
                try? await Task.sleep(for: .milliseconds(900))
                await MainActor.run {
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                await MainActor.run {
                    self.isPlaying = false
                    self.successfulGroupID = nil
                    self.updateSpeakerCards()
                    self.showError(error.localizedDescription)
                    self.notifyButton.isHidden = false
                }
            }
        }
    }

    private func setStatus(_ text: String, loading: Bool) {
        setStatus(text, indicator: loading ? .loading : .none)
    }

    private func setStatus(_ text: String, indicator: SharePlaybackVisualIndicator) {
        statusLabel.text = text
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.66)
        applyStatusIndicator(indicator)
    }

    private func markSuccess(on group: ShareSpeakerGroup) {
        successfulGroupID = group.id
        setStatus("Playing on \(group.displayName)", indicator: .success)
        statusLabel.textColor = UIColor(red: 0.52, green: 1.0, blue: 0.68, alpha: 1)
        updateSpeakerCards()
    }

    private func showError(_ message: String?) {
        statusLabel.text = message ?? "Something went wrong."
        statusLabel.textColor = UIColor(red: 1.0, green: 0.45, blue: 0.55, alpha: 1)
        applyStatusIndicator(.none)
    }

    private func applyStatusIndicator(_ indicator: SharePlaybackVisualIndicator) {
        indicator.showsSpinner ? spinner.startAnimating() : spinner.stopAnimating()
        spinner.isHidden = !indicator.showsSpinner

        if let systemImageName = indicator.systemImageName {
            statusIconView.image = UIImage(systemName: systemImageName)
            statusIconView.isHidden = false
        } else {
            statusIconView.isHidden = true
        }
    }

    private func loadArtwork(from urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else {
            artworkImageView.isHidden = true
            artworkFallbackView.isHidden = false
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                return
            }
            await MainActor.run {
                self.artworkImageView.image = image
                self.artworkImageView.isHidden = false
                self.artworkFallbackView.isHidden = true
            }
        }
    }

    @objc private func notifyButtonTapped() {
        setStatus("Preparing notification...", loading: true)
        scheduleOpenNotification(requestAuthorizationIfNeeded: true) { [weak self] scheduled in
            DispatchQueue.main.async {
                guard let self else { return }
                if scheduled {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.showError("Still saved. Open Charm Player from the Home Screen.")
                }
            }
        }
    }

    private func scheduleOpenNotification(
        requestAuthorizationIfNeeded: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.addOpenNotification(completion: completion)
            case .notDetermined where requestAuthorizationIfNeeded:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        completion(false)
                        return
                    }
                    self.addOpenNotification(completion: completion)
                }
            default:
                completion(false)
            }
        }
    }

    private func addOpenNotification(completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "Open Charm Player"
        content.body = "Tap to choose a speaker for your Apple Music share."
        content.sound = .default
        content.userInfo = ["route": "appleMusicShare"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "apple-music-share-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            completion(error == nil)
        }
    }

    private func loadFirstSharedValue(completion: @escaping (Result<String, Error>) -> Void) {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []

        loadFirstValue(from: providers, typeIdentifier: UTType.url.identifier) { urlResult in
            switch urlResult {
            case .success(let value):
                completion(.success(value))
            case .failure:
                self.loadFirstValue(from: providers, typeIdentifier: UTType.plainText.identifier) { textResult in
                    switch textResult {
                    case .success(let value):
                        completion(.success(value))
                    case .failure:
                        completion(.failure(AppleMusicShareExtensionStore.StoreError.missingAppleMusicURL))
                    }
                }
            }
        }
    }

    private func loadFirstValue(
        from providers: [NSItemProvider],
        typeIdentifier: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var pendingProviders = providers[...]

        func loadNext() {
            guard !pendingProviders.isEmpty else {
                completion(.failure(AppleMusicShareExtensionStore.StoreError.missingAppleMusicURL))
                return
            }

            let provider = pendingProviders.removeFirst()
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                loadNext()
                return
            }

            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                if let url = item as? URL {
                    completion(.success(url.absoluteString))
                } else if let string = item as? String {
                    completion(.success(string))
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    completion(.success(string))
                } else {
                    loadNext()
                }
            }
        }

        loadNext()
    }
}

private final class SpeakerGroupCard: UIControl {
    private let iconView = UIImageView(image: UIImage(systemName: "hifispeaker.2.fill"))
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let waveformView = PlaybackWaveformView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
                self.alpha = self.isHighlighted ? 0.82 : 1
            }
        }
    }

    func configure(
        group: ShareSpeakerGroup,
        status: ShareSpeakerPlaybackStatus?,
        nowPlaying: ShareSpeakerNowPlaying?,
        artworkImage: UIImage?,
        isSelected: Bool,
        isLoading: Bool,
        isSuccessful: Bool
    ) {
        titleLabel.text = group.displayName
        detailLabel.text = group.detailText(status: status, nowPlaying: nowPlaying)
        if let artworkImage {
            iconView.image = artworkImage
            iconView.tintColor = nil
            iconView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
            iconView.contentMode = .scaleAspectFill
        } else {
            iconView.image = UIImage(systemName: "hifispeaker.2.fill")
            iconView.tintColor = UIColor.white.withAlphaComponent(0.85)
            iconView.backgroundColor = .clear
            iconView.contentMode = .center
        }
        layer.borderColor = (isSelected
            ? UIColor(red: 1.0, green: 0.22, blue: 0.47, alpha: 1)
            : UIColor.white.withAlphaComponent(0.16)).cgColor
        backgroundColor = isSelected
            ? UIColor(red: 0.22, green: 0.06, blue: 0.12, alpha: 0.86)
            : UIColor.white.withAlphaComponent(0.08)

        let isActivelyPlaying = isSuccessful || status == .playing
        let indicator: SharePlaybackVisualIndicator = isLoading
            ? .loading
            : (isActivelyPlaying ? .playingWaveform : .restingWaveform)
        let waveformColor = isSuccessful
            ? UIColor(red: 0.52, green: 1.0, blue: 0.68, alpha: 1)
            : UIColor.white.withAlphaComponent(isActivelyPlaying ? 0.92 : 0.48)
        waveformView.configure(indicator: indicator, color: waveformColor)
        waveformView.isHidden = indicator.showsSpinner
        spinner.isHidden = !indicator.showsSpinner
        indicator.showsSpinner ? spinner.startAnimating() : spinner.stopAnimating()

        accessibilityTraits = .button
        accessibilityLabel = "\(group.displayName), \(detailLabel.text ?? "Tap to play")"
    }

    private func configure() {
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true

        iconView.tintColor = UIColor.white.withAlphaComponent(0.85)
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 8
        iconView.clipsToBounds = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        detailLabel.numberOfLines = 1

        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        waveformView.translatesAutoresizingMaskIntoConstraints = false

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 8
        iconContainer.clipsToBounds = true
        iconContainer.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        iconContainer.addSubview(iconView)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let indicatorContainer = UIView()
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.addSubview(waveformView)
        indicatorContainer.addSubview(spinner)

        let stack = UIStackView(arrangedSubviews: [iconContainer, textStack, indicatorContainer])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        [stack, iconContainer, textStack, indicatorContainer].forEach {
            $0.isUserInteractionEnabled = false
        }
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 82),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),

            indicatorContainer.widthAnchor.constraint(equalToConstant: 34),
            indicatorContainer.heightAnchor.constraint(equalToConstant: 42),
            waveformView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            waveformView.widthAnchor.constraint(equalToConstant: SharePlaybackWaveformLayout.size.width),
            waveformView.heightAnchor.constraint(equalToConstant: SharePlaybackWaveformLayout.size.height),
            spinner.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor)
        ])
    }
}

private final class PlaybackWaveformView: UIView {
    private static let animationKey = "share.waveform.levels"

    private let bars: [UIView] = (0..<5).map { _ in UIView() }
    private var heightConstraints: [NSLayoutConstraint] = []
    private var isAnimatingWaveform = false

    private let restingHeights = SharePlaybackWaveformLayout.restingHeights
    private let activeHeights = SharePlaybackWaveformLayout.activeHeights

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(indicator: SharePlaybackVisualIndicator, color: UIColor) {
        isHidden = !indicator.showsWaveform
        bars.forEach { $0.backgroundColor = color }

        guard indicator.showsWaveform else {
            stopAnimating()
            return
        }

        if indicator.animatesWaveform {
            applyHeights(activeHeights)
            startAnimating()
        } else {
            stopAnimating()
            applyHeights(restingHeights)
        }
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false

        let stack = UIStackView(arrangedSubviews: bars)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalCentering
        stack.spacing = SharePlaybackWaveformLayout.barSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        addSubview(stack)

        for (index, bar) in bars.enumerated() {
            bar.layer.cornerRadius = SharePlaybackWaveformLayout.barWidth / 2
            bar.clipsToBounds = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            let height = bar.heightAnchor.constraint(equalToConstant: restingHeights[index])
            heightConstraints.append(height)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: SharePlaybackWaveformLayout.barWidth),
                height
            ])
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func applyHeights(_ heights: [CGFloat]) {
        for (index, constraint) in heightConstraints.enumerated() {
            constraint.constant = heights[index]
        }
        setNeedsLayout()
    }

    private func startAnimating() {
        guard !isAnimatingWaveform else { return }
        isAnimatingWaveform = true

        for (index, bar) in bars.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = [0.55, 1.0, 0.68, 0.92, 0.58]
            animation.keyTimes = [0, 0.24, 0.52, 0.78, 1]
            animation.duration = 0.82 + (Double(index) * 0.05)
            animation.beginTime = CACurrentMediaTime() + (Double(index) * 0.06)
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            bar.layer.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopAnimating() {
        guard isAnimatingWaveform else { return }
        isAnimatingWaveform = false
        for bar in bars {
            bar.layer.removeAnimation(forKey: Self.animationKey)
            bar.transform = .identity
        }
    }
}
