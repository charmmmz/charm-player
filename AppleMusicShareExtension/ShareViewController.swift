import UIKit
import UniformTypeIdentifiers
import UserNotifications

final class ShareViewController: UIViewController {
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        processSharedInput()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        openButton.setTitle("Open Charm Player", for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.addTarget(self, action: #selector(openButtonTapped), for: .touchUpInside)
        openButton.isHidden = true

        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(doneButtonTapped), for: .touchUpInside)
        doneButton.isHidden = true

        let buttonStack = UIStackView(arrangedSubviews: [openButton, doneButton])
        buttonStack.axis = .vertical
        buttonStack.spacing = 10
        buttonStack.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            activityIndicator,
            titleLabel,
            detailLabel,
            buttonStack
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])

        setLoading(title: "Saving Apple Music link", detail: nil)
    }

    private func processSharedInput() {
        loadFirstSharedValue { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let value):
                    self.saveAndOpen(value)
                case .failure(let error):
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func saveAndOpen(_ value: String) {
        do {
            _ = try AppleMusicShareExtensionStore.saveFirstAppleMusicURL(from: value)
            setLoading(title: "Saved to Charm Player", detail: "Opening Charm Player...")
            openContainingApp { [weak self] success in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if success {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    } else {
                        self.showNotificationFallbackAfterBlockedOpen()
                    }
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func setLoading(title: String, detail: String?) {
        titleLabel.text = title
        detailLabel.text = detail
        activityIndicator.startAnimating()
        openButton.isHidden = true
        doneButton.isHidden = true
    }

    private func showSavedFallback() {
        activityIndicator.stopAnimating()
        titleLabel.text = "Saved to Charm Player"
        detailLabel.text = "iOS blocked opening from Apple Music. Use a notification or open Charm Player manually."
        openButton.setTitle("Notify to Open", for: .normal)
        openButton.isHidden = false
        doneButton.isHidden = false
    }

    private func showNotificationFallbackAfterBlockedOpen() {
        scheduleOpenNotification(requestAuthorizationIfNeeded: false) { [weak self] scheduled in
            DispatchQueue.main.async {
                guard let self else { return }
                if scheduled {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.showSavedFallback()
                }
            }
        }
    }

    private func showError(_ message: String) {
        activityIndicator.stopAnimating()
        titleLabel.text = "Could not save link"
        detailLabel.text = message
        openButton.isHidden = true
        doneButton.isHidden = false
    }

    @objc private func openButtonTapped() {
        setLoading(title: "Preparing notification", detail: nil)
        scheduleOpenNotification(requestAuthorizationIfNeeded: true) { [weak self] scheduled in
            DispatchQueue.main.async {
                guard let self else { return }
                if scheduled {
                    self.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self.showSavedFallback()
                    self.detailLabel.text = "Still saved. Open Charm Player from the Home Screen."
                }
            }
        }
    }

    @objc private func doneButtonTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func openContainingApp(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "sonoswidget://share/apple-music") else {
            completion(false)
            return
        }
        extensionContext?.open(url, completionHandler: completion)
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
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else {
            completion(.failure(AppleMusicShareExtensionStore.StoreError.missingAppleMusicURL))
            return
        }

        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let url = item as? URL {
                completion(.success(url.absoluteString))
            } else if let url = item as? NSURL {
                completion(.success(url.absoluteString ?? ""))
            } else if let string = item as? String {
                completion(.success(string))
            } else if let data = item as? Data,
                      let string = String(data: data, encoding: .utf8) {
                completion(.success(string))
            } else {
                completion(.failure(AppleMusicShareExtensionStore.StoreError.missingAppleMusicURL))
            }
        }
    }
}
