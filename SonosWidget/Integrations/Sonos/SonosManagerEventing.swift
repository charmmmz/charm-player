import Foundation
import Network
import SwiftUI
import WidgetKit
import ActivityKit

extension SonosManager {

    // MARK: - Background Keepalive for Live Activity

    /// When music is playing and the app moves to background, iOS suspends our Timer.
    /// This grabs ~30s of background execution time and polls every 5s so the Live
    /// Activity (track title, progress timestamps) stays fresh through track changes.
    @MainActor
    func startBackgroundKeepalive() {
        guard Self.shouldStartBackgroundKeepalive(
            currentActivityExists: currentActivity != nil,
            relayAvailable: RelayManager.shared.isAvailable
        ) else { return }
        stopBackgroundKeepalive()

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SonosLiveActivity") { [weak self] in
            self?.stopBackgroundKeepalive()
        }

        backgroundKeepaliveTask = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { break }
                await self.refreshState()
            }
            await MainActor.run { self?.stopBackgroundKeepalive() }
        }
    }

    nonisolated static func shouldStartBackgroundKeepalive(
        currentActivityExists: Bool,
        relayAvailable: Bool
    ) -> Bool {
        currentActivityExists && !relayAvailable
    }

    @MainActor
    func stopBackgroundKeepalive() {
        backgroundKeepaliveTask?.cancel()
        backgroundKeepaliveTask = nil
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Sonos Event Subscriptions

    func ensureEventSubscriptionsIfNeeded() {
        guard transportBackend == .lan, let ip = playbackIP else {
            stopEventSubscriptions()
            return
        }
        if eventSubscriptionIP == ip, eventSubscriptionTask != nil {
            return
        }

        eventSubscriptionTask?.cancel()
        eventSubscriptionTask = Task { @MainActor [weak self] in
            await self?.runEventSubscriptionLoop(ip: ip)
        }
    }

    @MainActor
    func runEventSubscriptionLoop(ip: String) async {
        defer {
            if eventSubscriptionIP == ip {
                eventSubscriptionTask = nil
            }
        }

        do {
            let callbackURL = try eventCallbackURL()
            eventSubscriptionIP = ip
            eventSubscriptions.removeAll()

            while !Task.isCancelled, playbackIP == ip, transportBackend == .lan {
                await subscribeMissingEventServices(ip: ip, callbackURL: callbackURL)
                let delay = nextEventRenewalDelay()

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }

                guard !Task.isCancelled, playbackIP == ip, transportBackend == .lan else { break }
                await renewEventSubscriptions(ip: ip)
            }
        } catch {
            eventSubscriptionIP = nil
            eventSubscriptions.removeAll()
            eventListener?.stop()
            eventListener = nil
            SonosLog.debug(.sonosEvents, "subscription listener unavailable: \(error)")
        }
    }

    @MainActor
    func subscribeMissingEventServices(ip: String, callbackURL: URL) async {
        for service in Self.sonosEventServices where eventSubscriptions.subscription(for: service) == nil {
            do {
                let subscription = try await SonosEventSubscriptionClient.subscribe(
                    ip: ip,
                    service: service,
                    callbackURL: callbackURL,
                    timeoutSeconds: Self.sonosEventSubscriptionTimeout)
                guard playbackIP == ip, transportBackend == .lan else { return }
                eventSubscriptions.replace(subscription)
                SonosLog.info(.sonosEvents, "subscribed \(service) sid=\(subscription.sid)")
            } catch {
                SonosLog.debug(.sonosEvents, "subscribe \(service) failed: \(error)")
            }
        }
    }

    @MainActor
    func renewEventSubscriptions(ip: String) async {
        for subscription in eventSubscriptions.subscriptions {
            do {
                let renewed = try await SonosEventSubscriptionClient.renew(
                    ip: ip,
                    existingSubscription: subscription,
                    timeoutSeconds: Self.sonosEventSubscriptionTimeout)
                guard playbackIP == ip, transportBackend == .lan else { return }
                eventSubscriptions.replace(renewed)
                SonosLog.debug(.sonosEvents, "renewed \(renewed.service) sid=\(renewed.sid)")
            } catch {
                eventSubscriptions.remove(sid: subscription.sid)
                SonosLog.debug(.sonosEvents, "renew \(subscription.service) failed: \(error)")
            }
        }
    }

    func nextEventRenewalDelay() -> Int {
        let delays = eventSubscriptions.subscriptions.map(\.renewalDelaySeconds)
        return delays.min() ?? 60
    }

    func eventCallbackURL() throws -> URL {
        if let callbackURL = eventListener?.callbackURL {
            return callbackURL
        }

        let listener = eventListener ?? SonosEventListener { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleSonosEvent(notification)
            }
        }
        let callbackURL = try listener.start()
        eventListener = listener
        return callbackURL
    }

    func stopEventSubscriptions(unsubscribe: Bool = true) {
        eventSubscriptionTask?.cancel()
        eventSubscriptionTask = nil
        eventDrivenRefreshTask?.cancel()
        eventDrivenRefreshTask = nil
        pendingEventRefreshServices.removeAll()
        pendingRenderingControlIncludesSoundbarEQ = false

        let ip = eventSubscriptionIP
        let subscriptions = eventSubscriptions.subscriptions
        eventSubscriptionIP = nil
        eventSubscriptions.removeAll()
        eventListener?.stop()
        eventListener = nil

        guard unsubscribe, let ip else { return }
        Task {
            for subscription in subscriptions {
                try? await SonosEventSubscriptionClient.unsubscribe(ip: ip, subscription: subscription)
            }
        }
    }

    @MainActor
    func handleSonosEvent(_ notification: SonosEventNotification) {
        guard let service = eventSubscriptions.service(for: notification) else {
            SonosLog.debug(.sonosEvents, "ignored notification for unknown sid=\(notification.sid)")
            return
        }

        SonosLog.debug(.sonosEvents, "notify \(service) seq=\(notification.sequence.map(String.init) ?? "?")")
        scheduleEventDrivenRefresh(for: service, notificationBody: notification.body)
    }

    @MainActor
    func scheduleEventDrivenRefresh(
        for service: SonosEventService,
        notificationBody: String = ""
    ) {
        pendingEventRefreshServices.insert(service)
        if service == .renderingControl {
            pendingRenderingControlIncludesSoundbarEQ =
                pendingRenderingControlIncludesSoundbarEQ
                || Self.renderingControlEventContainsSoundbarEQ(notificationBody)
        }
        eventDrivenRefreshTask?.cancel()
        eventDrivenRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled, self.transportBackend == .lan else { return }

            let services = self.pendingEventRefreshServices
            let includeSoundbarEQ = self.pendingRenderingControlIncludesSoundbarEQ
            self.pendingEventRefreshServices.removeAll()
            self.pendingRenderingControlIncludesSoundbarEQ = false

            if services.contains(.zoneGroupTopology) {
                await self.reloadTopology()
            }
            if services.contains(.contentDirectory) {
                if self.queueLoaded {
                    await self.loadQueue()
                }
            }
            if services.contains(.avTransport) || services.contains(.contentDirectory) {
                // Relay snapshots are the preferred foreground read path when
                // available; refreshState() falls back to this same LAN path.
                await self.refreshState()
            } else if services.contains(.renderingControl) {
                await self.refreshVolumeStateLAN(
                    includeSoundbarEQ: includeSoundbarEQ
                )
            }
        }
    }

    /// RenderingControl carries high-frequency volume events as well as the
    /// soundbar-only EQ values. Keep ordinary volume events on the lightweight
    /// path without losing external Night Sound / Speech Enhancement changes.
    nonisolated static func renderingControlEventContainsSoundbarEQ(_ body: String) -> Bool {
        let normalized = body.lowercased()
        return normalized.contains("nightmode")
            || normalized.contains("dialoglevel")
            || normalized.contains("speechenhanceenabled")
    }

    // MARK: - Position Timer

    func managePositionTimer() {
        if isPlaying && durationSeconds > 0 {
            if positionTask == nil {
                positionTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        guard self.isPlaying, self.durationSeconds > 0 else {
                            self.positionTask = nil
                            return
                        }
                        self.positionSeconds = min(self.positionSeconds + 1, self.durationSeconds)
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        } else {
            positionTask?.cancel()
            positionTask = nil
        }
    }

}
