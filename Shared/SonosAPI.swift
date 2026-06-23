import Foundation

struct SonosDIDLResource: Equatable, Sendable {
    var uri: String
    var protocolInfo: String?

    init(uri: String, protocolInfo: String? = nil) {
        self.uri = uri
        self.protocolInfo = protocolInfo
    }
}

struct SonosDIDLElement: Equatable, Sendable {
    var tag: String
    var id: String
    var parentID: String
    var restricted: Bool
    var title: String
    var upnpClass: String
    var resources: [SonosDIDLResource]
    var creator: String?
    var album: String?
    var albumArtist: String?
    var albumArtURI: String?
    var rType: String?
    var rDescription: String?
    var resourceMetaData: String?
    var desc: String?

    init(tag: String = "item",
         id: String,
         parentID: String = "",
         restricted: Bool = true,
         title: String,
         upnpClass: String,
         resources: [SonosDIDLResource] = [],
         creator: String? = nil,
         album: String? = nil,
         albumArtist: String? = nil,
         albumArtURI: String? = nil,
         rType: String? = nil,
         rDescription: String? = nil,
         resourceMetaData: String? = nil,
         desc: String? = nil) {
        self.tag = tag
        self.id = id
        self.parentID = parentID
        self.restricted = restricted
        self.title = title
        self.upnpClass = upnpClass
        self.resources = resources
        self.creator = creator
        self.album = album
        self.albumArtist = albumArtist
        self.albumArtURI = albumArtURI
        self.rType = rType
        self.rDescription = rDescription
        self.resourceMetaData = resourceMetaData
        self.desc = desc
    }
}

enum SonosDIDLBuilder {
    private nonisolated static let didlNamespace =
        "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
        "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
        "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
        "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"

    nonisolated static func document(_ elements: [SonosDIDLElement]) -> String {
        didlNamespace + elements.map(elementXML).joined() + "</DIDL-Lite>"
    }

    nonisolated static func item(id: String,
                                 parentID: String = "",
                                 title: String,
                                 upnpClass: String,
                                 resources: [SonosDIDLResource] = [],
                                 creator: String? = nil,
                                 album: String? = nil,
                                 albumArtist: String? = nil,
                                 albumArtURI: String? = nil,
                                 desc: String? = nil) -> String {
        document([
            SonosDIDLElement(
                id: id,
                parentID: parentID,
                title: title,
                upnpClass: upnpClass,
                resources: resources,
                creator: creator,
                album: album,
                albumArtist: albumArtist,
                albumArtURI: albumArtURI,
                desc: desc)
        ])
    }

    private nonisolated static func elementXML(_ didlElement: SonosDIDLElement) -> String {
        let tag = didlElement.tag == "container" ? "container" : "item"
        var xml = "<\(tag) id=\"\(SonosAPI.escapeXML(didlElement.id))\" " +
            "parentID=\"\(SonosAPI.escapeXML(didlElement.parentID))\" " +
            "restricted=\"\(didlElement.restricted ? "true" : "false")\">"
        xml += element("dc:title", didlElement.title)
        for resource in didlElement.resources {
            if let protocolInfo = resource.protocolInfo, !protocolInfo.isEmpty {
                xml += "<res protocolInfo=\"\(SonosAPI.escapeXML(protocolInfo))\">" +
                    "\(SonosAPI.escapeXML(resource.uri))</res>"
            } else {
                xml += element("res", resource.uri)
            }
        }
        xml += optionalElement("dc:creator", didlElement.creator)
        xml += optionalElement("upnp:album", didlElement.album)
        xml += optionalElement("r:albumArtist", didlElement.albumArtist)
        xml += element("upnp:class", didlElement.upnpClass)
        xml += optionalElement("upnp:albumArtURI", didlElement.albumArtURI)
        xml += optionalElement("r:type", didlElement.rType)
        xml += optionalElement("r:description", didlElement.rDescription)
        xml += optionalElement("r:resMD", didlElement.resourceMetaData)
        if let desc = didlElement.desc {
            xml += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">" +
                "\(SonosAPI.escapeXML(desc))</desc>"
        }
        xml += "</\(tag)>"
        return xml
    }

    private nonisolated static func optionalElement(_ tag: String, _ value: String?) -> String {
        guard let value else { return "" }
        return element(tag, value)
    }

    private nonisolated static func element(_ tag: String, _ value: String) -> String {
        "<\(tag)>\(SonosAPI.escapeXML(value))</\(tag)>"
    }
}

enum SonosPlayableURIBuilder {
    nonisolated static func encodedObjectID(_ objectID: String) -> String {
        objectID.replacingOccurrences(of: ":", with: "%3a")
    }

    nonisolated static func serviceURI(scheme: String,
                                       objectID: String,
                                       localSid: Int,
                                       flags: Int,
                                       accountID: String,
                                       fileExtension: String = "") -> String {
        "\(scheme):\(encodedObjectID(objectID))\(fileExtension)?sid=\(localSid)&flags=\(flags)&sn=\(accountID)"
    }

    nonisolated static func containerURI(prefix: String,
                                         objectID: String,
                                         localSid: Int,
                                         flags: Int,
                                         accountID: String) -> String {
        serviceURI(
            scheme: "x-rincon-cpcontainer",
            objectID: "\(prefix)\(objectID)",
            localSid: localSid,
            flags: flags,
            accountID: accountID)
    }
}

struct SonosQueuedURI: Equatable, Sendable {
    var uri: String
    var metadata: String
}

struct SonosQueueReplacementPlaybackPlan: Equatable, Sendable {
    static let defaultBackgroundBatchSize = 16
    static let fallbackBackgroundBatchSizes: [Int] = []

    var first: SonosQueuedURI
    var remaining: [SonosQueuedURI]

    init?(items: [SonosQueuedURI]) {
        guard let first = items.first else { return nil }
        self.first = first
        self.remaining = Array(items.dropFirst())
    }

    var totalCount: Int {
        1 + remaining.count
    }

    func remainingBatches(maxBatchSize: Int = Self.defaultBackgroundBatchSize) -> [[SonosQueuedURI]] {
        let batchSize = max(1, maxBatchSize)
        guard !remaining.isEmpty else { return [] }
        return stride(from: 0, to: remaining.count, by: batchSize).map { start in
            Array(remaining[start..<min(start + batchSize, remaining.count)])
        }
    }

    static func fallbackBatchSizes(afterFailedBatchSize failedBatchSize: Int) -> [Int] {
        fallbackBackgroundBatchSizes.filter { $0 < failedBatchSize }
    }
}

struct SonosQueueBatchAddError: Error, CustomStringConvertible {
    var underlying: Error
    var failedChunkStart: Int
    var remainingItems: [SonosQueuedURI]

    var description: String {
        "SonosQueueBatchAddError(failedChunkStart=\(failedChunkStart), " +
            "remainingCount=\(remainingItems.count), underlying=\(underlying))"
    }
}

enum SonosAPI {

    nonisolated static let port = 1400
    private nonisolated static let addMultipleURIsToQueueChunkSize = 16
    private nonisolated static let avTransport = "/MediaRenderer/AVTransport/Control"
    private nonisolated static let renderingControl = "/MediaRenderer/RenderingControl/Control"
    private nonisolated static let groupRenderingControl = "/MediaRenderer/GroupRenderingControl/Control"
    private nonisolated static let zoneGroupTopology = "/ZoneGroupTopology/Control"
    private nonisolated static let contentDirectory = "/MediaServer/ContentDirectory/Control"
    private nonisolated static let deviceProperties = "/DeviceProperties/Control"
    private nonisolated static let systemProperties = "/SystemProperties/Control"

    // MARK: - Playback Controls

    nonisolated static func play(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Play",
                           body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    nonisolated static func pause(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Pause",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func next(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Next",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func previous(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Previous",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func getPlayMode(ip: String) async throws -> (shuffle: Bool, repeat: RepeatMode) {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetTransportSettings", body: "<InstanceID>0</InstanceID>")
        let raw = extractTag("PlayMode", from: xml) ?? "NORMAL"
        switch raw {
        case "SHUFFLE":              return (true,  .all)
        case "SHUFFLE_NOREPEAT":     return (true,  .off)
        case "SHUFFLE_REPEAT_ONE":   return (true,  .one)
        case "REPEAT_ALL":           return (false, .all)
        case "REPEAT_ONE":           return (false, .one)
        default:                     return (false, .off)
        }
    }

    nonisolated static func setPlayMode(ip: String, shuffle: Bool, repeat repeatMode: RepeatMode) async throws {
        let mode: String
        switch (shuffle, repeatMode) {
        case (true,  .all): mode = "SHUFFLE"
        case (true,  .one): mode = "SHUFFLE_REPEAT_ONE"
        case (true,  .off): mode = "SHUFFLE_NOREPEAT"
        case (false, .all): mode = "REPEAT_ALL"
        case (false, .one): mode = "REPEAT_ONE"
        case (false, .off): mode = "NORMAL"
        }
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "SetPlayMode",
                           body: "<InstanceID>0</InstanceID><NewPlayMode>\(mode)</NewPlayMode>")
    }

    nonisolated static func seek(ip: String, position: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Seek",
                           body: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(position)</Target>")
    }

    // MARK: - State Queries

    nonisolated static func getTransportInfo(ip: String) async throws -> TransportState {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetTransportInfo", body: "<InstanceID>0</InstanceID>")
        let raw = extractTag("CurrentTransportState", from: xml) ?? "UNKNOWN"
        return TransportState(rawValue: raw) ?? .unknown
    }

    nonisolated static func getMediaInfo(ip: String) async throws -> String {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetMediaInfo", body: "<InstanceID>0</InstanceID>")
        return extractTag("CurrentURI", from: xml) ?? ""
    }

    /// Soundbar audio-input format, exposed through `DeviceProperties.GetZoneInfo`'s
    /// `HTAudioIn` field. The returned integer is a Sonos-internal code that
    /// `TVAudioFormat.from(htAudioInCode:)` translates into a friendly label
    /// ("Dolby Atmos (TrueHD)", "Dolby 5.1", "PCM 2.0", "No input"…).
    ///
    /// `HTAudioIn` is present on every Sonos device but only meaningful on
    /// soundbars (Beam, Arc, Arc Ultra, Playbar). For non-HT speakers it stays
    /// at `0` ("No input connected"). Callers should gate this behind a
    /// soundbar check (e.g. when `TrackURI` is `x-sonos-htastream:`).
    nonisolated static func getHTAudioIn(ip: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: deviceProperties,
                                 service: "DeviceProperties",
                                 action: "GetZoneInfo", body: "")
        guard let raw = extractTag("HTAudioIn", from: xml), let code = Int(raw) else {
            return 0
        }
        return code
    }

    nonisolated static func getZoneSerialNumber(ip: String) async throws -> String {
        let xml = try await soap(ip: ip, endpoint: deviceProperties,
                                 service: "DeviceProperties",
                                 action: "GetZoneInfo", body: "")
        return extractTag("SerialNumber", from: xml) ?? ""
    }

    nonisolated static func getSystemProperty(ip: String, variableName: String) async throws -> String {
        let xml = try await soap(ip: ip, endpoint: systemProperties,
                                 service: "SystemProperties",
                                 action: "GetString",
                                 body: "<VariableName>\(escapeXML(variableName))</VariableName>")
        return extractTag("StringValue", from: xml) ?? ""
    }

    // MARK: - Soundbar EQ Toggles (NightMode / DialogLevel / etc.)

    /// Read a soundbar EQ flag via `RenderingControl.GetEQ`. Sonos overloads
    /// the same SOAP action for several speaker-tuning toggles, distinguished
    /// by `EQType`. Returns `false` for non-soundbars (the speaker just
    /// reports `0`).
    ///
    /// - `NightMode`: 夜间模式 — softens loud peaks (explosions, music
    ///   stings) so dialogue stays at a comfortable level.
    /// - `DialogLevel`: 人声增强 — boosts the center channel / vocal band.
    /// - `SurroundEnable` / `SubEnable` / others — surround speakers + sub
    ///   wired to the same action.
    nonisolated static func getEQ(ip: String, eqType: String) async throws -> Bool {
        let xml = try await soap(ip: ip, endpoint: renderingControl,
                                 service: "RenderingControl", action: "GetEQ",
                                 body: "<InstanceID>0</InstanceID>" +
                                       "<EQType>\(eqType)</EQType>")
        guard let raw = extractTag("CurrentValue", from: xml) else { return false }
        return raw == "1"
    }

    /// Counterpart to `getEQ` — flip a soundbar EQ toggle.
    nonisolated static func setEQ(ip: String, eqType: String, enabled: Bool) async throws {
        try await setEQLevel(ip: ip, eqType: eqType, level: enabled ? 1 : 0)
    }

    /// Read the raw integer value of an EQ field. Most flags are still 0/1
    /// (NightMode, SubEnable, …), but Arc Ultra and newer soundbars exposed
    /// `DialogLevel` as a 0–4 scale (Off / Low / Medium / High / Max), so we
    /// expose the raw integer and let callers decide how to interpret it.
    nonisolated static func getEQLevel(ip: String, eqType: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: renderingControl,
                                 service: "RenderingControl", action: "GetEQ",
                                 body: "<InstanceID>0</InstanceID>" +
                                       "<EQType>\(eqType)</EQType>")
        guard let raw = extractTag("CurrentValue", from: xml), let n = Int(raw) else {
            return 0
        }
        return n
    }

    nonisolated static func setEQLevel(ip: String, eqType: String, level: Int) async throws {
        _ = try await soap(ip: ip, endpoint: renderingControl,
                           service: "RenderingControl", action: "SetEQ",
                           body: "<InstanceID>0</InstanceID>" +
                                 "<EQType>\(eqType)</EQType>" +
                                 "<DesiredValue>\(level)</DesiredValue>")
    }

    /// Convenience wrapper — fetch the soundbar's TV-mode toggles in
    /// parallel. Newer Sonos firmware (Arc Ultra) splits Speech Enhancement
    /// into two fields:
    ///
    /// - `SpeechEnhanceEnabled` (bool) — master on/off; **does not** flip
    ///   `DialogLevel` to 0 when disabled.
    /// - `DialogLevel` (1–4) — intensity (Low / Med / High / Max), only
    ///   meaningful while `SpeechEnhanceEnabled = 1`.
    ///
    /// Older soundbars (Beam, original Arc, Ray) only expose `DialogLevel`
    /// as a 0/1 toggle and don't ship `SpeechEnhanceEnabled`. We probe both
    /// so the caller can compose the right `SpeechEnhancementLevel`:
    ///
    /// - If `SpeechEnhanceEnabled` returns 0 (or the field doesn't exist on
    ///   this bar but `DialogLevel` is also 0) → `.off`.
    /// - Otherwise the level we report is `DialogLevel` clamped to 1–4.
    nonisolated static func getSoundbarEQ(ip: String) async throws -> (night: Bool, speechEnabled: Bool, dialogLevel: Int) {
        // Fan out as detached tasks so we can `try?` the
        // `SpeechEnhanceEnabled` lookup independently — older soundbars
        // (Beam, original Arc, Ray) return a SOAP fault for that EQType
        // rather than silently 0, and we don't want one missing field to
        // tank the whole refresh.
        async let nightTask = getEQ(ip: ip, eqType: "NightMode")
        async let speechTask: Bool? = {
            try? await getEQ(ip: ip, eqType: "SpeechEnhanceEnabled")
        }()
        async let dialogTask = getEQLevel(ip: ip, eqType: "DialogLevel")

        let night = try await nightTask
        let dialog = try await dialogTask
        let speechProbe = await speechTask
        // Legacy bars: treat DialogLevel > 0 as "on" for the unified
        // SpeechEnhancementLevel mapping the UI uses.
        let enabled = speechProbe ?? (dialog > 0)
        return (night: night, speechEnabled: enabled, dialogLevel: dialog)
    }

    /// Returns the raw SOAP XML from GetPositionInfo (for diagnostic use).
    nonisolated static func getRawPositionInfo(ip: String) async throws -> String {
        try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                       action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
    }

    /// 1-based track number of whatever's currently selected in the
    /// queue. Used by `playNext` to compute an explicit insertion point
    /// — Sonos's `EnqueueAsNext=1` flag alone is firmware-dependent and
    /// on recent firmwares it ignores the hint and appends at the end of
    /// the queue (or the end of the current album), which is *not* what
    /// the user expects from "Play Next". Returns `nil` when there's no
    /// meaningful queue position (radio, TV, line-in).
    nonisolated static func getCurrentTrackNumber(ip: String) async throws -> Int? {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")
        guard let raw = extractTag("Track", from: xml), let n = Int(raw), n > 0 else {
            return nil
        }
        return n
    }

    nonisolated static func getPositionInfo(ip: String) async throws -> TrackInfo {
        let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                                 action: "GetPositionInfo", body: "<InstanceID>0</InstanceID>")

        let duration = extractTag("TrackDuration", from: xml)
        let position = extractTag("RelTime", from: xml)
        let trackURI = extractTag("TrackURI", from: xml) ?? ""

        var title = "Unknown"
        var artist = "Unknown"
        var album = "Unknown"
        var albumArtURL: String?
        var audioQuality: AudioQuality?

        let decodedURI = decodeXMLEntities(trackURI)
        let source = PlaybackSource.from(trackURI: decodedURI)
        var tvFormat: TVAudioFormat?

        // Soundbar TV input — HDMI eARC / optical / coax. Sonos doesn't expose
        // any of the audio-format info through `GetPositionInfo` /
        // `GetMediaInfo` (both return `NOT_IMPLEMENTED` placeholders), it lives
        // on `DeviceProperties.GetZoneInfo`'s `HTAudioIn` integer code. Fetch
        // it in parallel with the rest so we can stamp the codec / channel
        // layout into the returned TrackInfo.
        if source == .tv {
            if let code = try? await getHTAudioIn(ip: ip) {
                tvFormat = TVAudioFormat.from(htAudioInCode: code)
            }
        }

        if let raw = extractTag("TrackMetaData", from: xml) {
            let meta = decodeXMLEntities(raw)
            title = decodeXMLEntities(extractTag("dc:title", from: meta) ?? "Unknown")
            artist = decodeXMLEntities(extractTag("dc:creator", from: meta) ?? "Unknown")
            album = decodeXMLEntities(extractTag("upnp:album", from: meta) ?? "")

            // Radio streams put current track info in r:streamContent
            if let stream = extractTag("r:streamContent", from: meta), !stream.isEmpty {
                let decoded = decodeXMLEntities(stream)
                let fields = SonosRadioStreamContent.fields(from: decoded)
                if !fields.isEmpty {
                    // Pipe-delimited format: TYPE=SNG|TITLE ...|ARTIST ...|ALBUM ...
                    if let t = fields["TITLE"], !t.isEmpty { title = t }
                    if let a = fields["ARTIST"], !a.isEmpty { artist = a }
                    if let al = fields["ALBUM"], !al.isEmpty { album = al }
                } else if decoded.contains(" - ") {
                    let parts = decoded.split(separator: " - ", maxSplits: 1)
                    if parts.count == 2 {
                        artist = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                } else if artist == "Unknown" || artist.isEmpty {
                    title = decoded
                }
            }

            if let artPath = extractTag("upnp:albumArtURI", from: meta) {
                var decoded = decodeXMLEntities(artPath)
                if decoded.contains("%25") {
                    decoded = decoded.removingPercentEncoding ?? decoded
                }
                albumArtURL = decoded.hasPrefix("http") ? decoded : "http://\(ip):\(port)\(decoded)"
            }
            audioQuality = parseAudioQuality(from: meta, source: source)
        }

        // For TV input the speaker doesn't ship track metadata at all — the
        // earlier parse leaves title/artist/album as the literal "Unknown"
        // sentinel. Replace title with "TV" and surface the actual codec
        // ("Dolby Atmos · MAT", "Multichannel PCM · 5.1") in the artist
        // subtitle slot so the player headline carries the most useful
        // signal. Live/idle status is conveyed redundantly by the row of
        // chips below the headline + the breathing halo on the TV glyph.
        if source == .tv {
            title = "TV"
            if let format = tvFormat {
                artist = format.hasSignal ? format.geekLabel : format.statusLabel
            } else {
                artist = "Live audio"
            }
            album = ""
        }

        return TrackInfo(title: title, artist: artist, album: album,
                         albumArtURL: albumArtURL, duration: duration, position: position,
                         source: source, audioQuality: audioQuality,
                         trackURI: decodeXMLEntities(trackURI),
                         tvFormat: tvFormat)
    }

    // MARK: - Volume

    nonisolated static func getVolume(ip: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: renderingControl, service: "RenderingControl",
                                 action: "GetVolume",
                                 body: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        guard let str = extractTag("CurrentVolume", from: xml), let vol = Int(str) else { return 0 }
        return vol
    }

    nonisolated static func setVolume(ip: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        _ = try await soap(ip: ip, endpoint: renderingControl, service: "RenderingControl",
                           action: "SetVolume",
                           body: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(clamped)</DesiredVolume>")
    }

    /// Gets the group volume for a coordinator (represents all members proportionally).
    nonisolated static func getGroupVolume(ip: String) async throws -> Int {
        let xml = try await soap(ip: ip, endpoint: groupRenderingControl, service: "GroupRenderingControl",
                                 action: "GetGroupVolume",
                                 body: "<InstanceID>0</InstanceID>")
        guard let str = extractTag("CurrentVolume", from: xml), let vol = Int(str) else { return 0 }
        return vol
    }

    /// Sets volume for an entire group proportionally via GroupRenderingControl on the coordinator.
    nonisolated static func setGroupVolume(ip: String, volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        _ = try await soap(ip: ip, endpoint: groupRenderingControl, service: "GroupRenderingControl",
                           action: "SetGroupVolume",
                           body: "<InstanceID>0</InstanceID><DesiredVolume>\(clamped)</DesiredVolume>")
    }

    // MARK: - Queue

    nonisolated static func getQueue(ip: String, start: Int = 0, count: Int = 500) async throws -> QueueResult {
        let body = "<ObjectID>Q:0</ObjectID>" +
            "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
            "<Filter>*</Filter>" +
            "<StartingIndex>\(start)</StartingIndex>" +
            "<RequestedCount>\(count)</RequestedCount>" +
            "<SortCriteria></SortCriteria>"
        let xml = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                                 action: "Browse", body: body)
        let updateID = extractTag("UpdateID", from: xml) ?? "0"
        guard let result = extractTag("Result", from: xml) else {
            return QueueResult(items: [], updateID: updateID)
        }
        return QueueResult(items: parseQueueItems(decodeXMLEntities(result), speakerIP: ip),
                           updateID: updateID)
    }

    // MARK: - Queue Management

    @discardableResult
    nonisolated static func addURIToQueue(ip: String, uri: String, metadata: String,
                                          position: Int = 0, asNext: Bool = false) async throws -> Int {
        let escapedURI = escapeXML(uri)
        let escapedMeta = escapeXML(metadata)
        let startedAt = Date()
        SonosLog.debug(
            .playbackLink,
            "SOAP AddURIToQueue request host=\(ip) position=\(position) asNext=\(asNext) " +
                "uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
        do {
            let xml = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                               action: "AddURIToQueue",
                               body: "<InstanceID>0</InstanceID>" +
                               "<EnqueuedURI>\(escapedURI)</EnqueuedURI>" +
                               "<EnqueuedURIMetaData>\(escapedMeta)</EnqueuedURIMetaData>" +
                               "<DesiredFirstTrackNumberEnqueued>\(position)</DesiredFirstTrackNumberEnqueued>" +
                               "<EnqueueAsNext>\(asNext ? 1 : 0)</EnqueueAsNext>")
            let track = Int(extractTag("FirstTrackNumberEnqueued", from: xml) ?? "1") ?? 1
            SonosLog.debug(
                .playbackLink,
                "SOAP AddURIToQueue success host=\(ip) firstTrack=\(track) " +
                    "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "uri=\(SonosLog.playbackLinkValue(uri))")
            return track
        } catch {
            SonosLog.error(
                .playbackLink,
                "SOAP AddURIToQueue failed host=\(ip) position=\(position) asNext=\(asNext) " +
                    "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "error=\(error) uri=\(SonosLog.playbackLinkValue(uri)) " +
                    "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
            throw error
        }
    }

    nonisolated static func addMultipleURIsToQueue(ip: String,
                                                   items: [SonosQueuedURI],
                                                   containerURI: String = "",
                                                   containerMetadata: String = "",
                                                   position: Int = 0,
                                                   asNext: Bool = false,
                                                   chunkSize: Int = addMultipleURIsToQueueChunkSize) async throws {
        let startedAt = Date()
        let chunkSize = normalizedAddMultipleURIsChunkSize(chunkSize)
        SonosLog.debug(
            .playbackLink,
            "SOAP AddMultipleURIsToQueue request host=\(ip) count=\(items.count) " +
                "chunkSize=\(chunkSize) " +
                "position=\(position) asNext=\(asNext) " +
                "containerURI=\(SonosLog.playbackLinkValue(containerURI)) " +
                "firstURI=\(SonosLog.playbackLinkValue(items.first?.uri)) " +
                "lastURI=\(SonosLog.playbackLinkValue(items.last?.uri)) " +
                "containerMetadata=\(SonosLog.playbackMetadataSummary(containerMetadata)) " +
                "diagnostics=\(addMultipleURIsToQueueDiagnostics(items: items))")
        for start in stride(from: 0, to: items.count, by: chunkSize) {
            let end = min(start + chunkSize, items.count)
            let chunk = Array(items[start..<end])
            let body = addMultipleURIsToQueueBody(
                items: chunk,
                containerURI: containerURI,
                containerMetadata: containerMetadata,
                position: position,
                asNext: asNext)
            do {
                _ = try await soap(
                    ip: ip,
                    endpoint: avTransport,
                    service: "AVTransport",
                    action: "AddMultipleURIsToQueue",
                    body: body)
            } catch {
                SonosLog.error(
                    .playbackLink,
                    "SOAP AddMultipleURIsToQueue failed host=\(ip) count=\(items.count) " +
                        "chunkStart=\(start) chunkCount=\(chunk.count) " +
                        "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                        "error=\(error) firstURI=\(SonosLog.playbackLinkValue(chunk.first?.uri)) " +
                        "diagnostics=\(addMultipleURIsToQueueDiagnostics(items: chunk, bodyByteCount: body.utf8.count))")
                throw SonosQueueBatchAddError(
                    underlying: error,
                    failedChunkStart: start,
                    remainingItems: addMultipleURIsToQueueFallbackItems(
                        items: items,
                        failedChunkStart: start))
            }
            SonosLog.debug(
                .playbackLink,
                "SOAP AddMultipleURIsToQueue chunk success host=\(ip) " +
                    "chunkStart=\(start) chunkCount=\(chunk.count)")
        }
        SonosLog.debug(
            .playbackLink,
            "SOAP AddMultipleURIsToQueue success host=\(ip) count=\(items.count) " +
                "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
    }

    nonisolated static func addMultipleURIsToQueueDiagnostics(
        items: [SonosQueuedURI],
        bodyByteCount: Int? = nil
    ) -> String {
        var uriTypeCounts = [
            "librarytrack": 0,
            "song": 0,
            "container": 0,
            "other": 0
        ]
        for item in items {
            uriTypeCounts[addMultipleURIType(item.uri), default: 0] += 1
        }
        let uriTypes = [
            "librarytrack=\(uriTypeCounts["librarytrack"] ?? 0)",
            "song=\(uriTypeCounts["song"] ?? 0)",
            "container=\(uriTypeCounts["container"] ?? 0)",
            "other=\(uriTypeCounts["other"] ?? 0)"
        ].joined(separator: " ")

        let flags = Dictionary(
            grouping: items.compactMap { queryParameter("flags", in: $0.uri) },
            by: { $0 }
        )
        .map { "\($0.key):\($0.value.count)" }
        .sorted()
        .joined(separator: ",")

        let metadataBytes = items.reduce(0) { $0 + $1.metadata.utf8.count }
        let escapedMetadataCount = items.filter {
            $0.metadata.contains("&lt;") || $0.metadata.contains("&quot;")
        }.count
        let firstDecodedMetadata = decodeXMLEntities(items.first?.metadata ?? "")
        let firstTag = firstDIDLElementTag(in: firstDecodedMetadata)
        let firstMetadataID = diagnosticValue(firstTag.flatMap { attr("id", in: $0) })
        let firstParentID = diagnosticValue(firstTag.flatMap { attr("parentID", in: $0) })

        var parts = [
            "uriTypes=\(uriTypes)",
            "flags=\(flags.isEmpty ? "none" : flags)",
            "firstMetadataID=\(firstMetadataID)",
            "firstParentID=\(firstParentID)",
            "escapedMetadata=\(escapedMetadataCount)",
            "metadataBytes=\(metadataBytes)"
        ]
        if let bodyByteCount {
            parts.append("bodyBytes=\(bodyByteCount)")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func addMultipleURIsToQueueBodies(items: [SonosQueuedURI],
                                                        containerURI: String = "",
                                                        containerMetadata: String = "",
                                                        position: Int = 0,
                                                        asNext: Bool = false,
                                                        chunkSize: Int = addMultipleURIsToQueueChunkSize) -> [String] {
        guard !items.isEmpty else { return [] }
        let chunkSize = normalizedAddMultipleURIsChunkSize(chunkSize)
        return stride(from: 0, to: items.count, by: chunkSize).map { start in
            let chunk = Array(items[start..<min(start + chunkSize, items.count)])
            return addMultipleURIsToQueueBody(
                items: chunk,
                containerURI: containerURI,
                containerMetadata: containerMetadata,
                position: position,
                asNext: asNext)
        }
    }

    private nonisolated static func normalizedAddMultipleURIsChunkSize(_ chunkSize: Int) -> Int {
        max(1, chunkSize)
    }

    nonisolated static func addMultipleURIsToQueueFallbackItems(items: [SonosQueuedURI],
                                                                failedChunkStart: Int) -> [SonosQueuedURI] {
        guard items.indices.contains(failedChunkStart) else { return items }
        return Array(items[failedChunkStart...])
    }

    private nonisolated static func addMultipleURIsToQueueBody(items: [SonosQueuedURI],
                                                               containerURI: String,
                                                               containerMetadata: String,
                                                               position: Int,
                                                               asNext: Bool) -> String {
        let enqueuedURIs = items.map { addMultipleURIsToQueueURIArgument($0.uri) }.joined(separator: " ")
        let enqueuedMetadata = items.map(\.metadata).joined(separator: " ")
        return "<InstanceID>0</InstanceID>" +
            "<UpdateID>0</UpdateID>" +
            "<NumberOfURIs>\(items.count)</NumberOfURIs>" +
            "<EnqueuedURIs>\(escapeXML(enqueuedURIs))</EnqueuedURIs>" +
            "<EnqueuedURIsMetaData>\(escapeXML(enqueuedMetadata))</EnqueuedURIsMetaData>" +
            "<ContainerURI>\(escapeXML(containerURI))</ContainerURI>" +
            "<ContainerMetaData>\(escapeXML(containerMetadata))</ContainerMetaData>" +
            "<DesiredFirstTrackNumberEnqueued>\(position)</DesiredFirstTrackNumberEnqueued>" +
            "<EnqueueAsNext>\(asNext ? 1 : 0)</EnqueueAsNext>"
    }

    private nonisolated static func addMultipleURIsToQueueURIArgument(_ uri: String) -> String {
        uri.replacingOccurrences(of: " ", with: "%20")
    }

    private nonisolated static func addMultipleURIType(_ uri: String) -> String {
        let decoded = uri.removingPercentEncoding ?? uri
        let lowercased = decoded.lowercased()
        if lowercased.contains("librarytrack:") {
            return "librarytrack"
        }
        if lowercased.contains("song:") {
            return "song"
        }
        if lowercased.hasPrefix("x-rincon-cpcontainer:") {
            return "container"
        }
        return "other"
    }

    private nonisolated static func firstDIDLElementTag(in metadata: String) -> String? {
        let pattern = #"<(?:item|container)\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: metadata, range: NSRange(metadata.startIndex..., in: metadata)),
              let range = Range(match.range, in: metadata) else {
            return nil
        }
        return String(metadata[range])
    }

    private nonisolated static func diagnosticValue(_ value: String?) -> String {
        guard let value else { return "nil" }
        return value.isEmpty ? "<empty>" : value
    }

    nonisolated static func removeAllTracksFromQueue(ip: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "RemoveAllTracksFromQueue",
                           body: "<InstanceID>0</InstanceID>")
    }

    nonisolated static func removeTrackFromQueue(ip: String, objectID: String, updateID: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "RemoveTrackFromQueue",
                           body: "<InstanceID>0</InstanceID>" +
                           "<ObjectID>\(objectID)</ObjectID>" +
                           "<UpdateID>\(updateID)</UpdateID>")
    }

    nonisolated static func reorderTracksInQueue(ip: String, startIndex: Int, numTracks: Int,
                                                  insertBefore: Int, updateID: String) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "ReorderTracksInQueue",
                           body: "<InstanceID>0</InstanceID>" +
                           "<StartingIndex>\(startIndex)</StartingIndex>" +
                           "<NumberOfTracks>\(numTracks)</NumberOfTracks>" +
                           "<InsertBefore>\(insertBefore)</InsertBefore>" +
                           "<UpdateID>\(updateID)</UpdateID>")
    }

    nonisolated static func seekToTrack(ip: String, trackNumber: Int) async throws {
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport", action: "Seek",
                           body: "<InstanceID>0</InstanceID><Unit>TRACK_NR</Unit><Target>\(trackNumber)</Target>")
    }

    nonisolated static func setAVTransportToQueue(ip: String, speakerUUID: String) async throws {
        let queueURI = "x-rincon-queue:\(speakerUUID)#0"
        SonosLog.debug(
            .playbackLink,
            "SOAP SetAVTransportURI queue request host=\(ip) uri=\(SonosLog.playbackLinkValue(queueURI))")
        _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                           action: "SetAVTransportURI",
                           body: "<InstanceID>0</InstanceID>" +
                           "<CurrentURI>\(queueURI)</CurrentURI>" +
                           "<CurrentURIMetaData></CurrentURIMetaData>")
    }

    nonisolated static func setAVTransportURI(ip: String, uri: String, metadata: String = "") async throws {
        let startedAt = Date()
        SonosLog.debug(
            .playbackLink,
            "SOAP SetAVTransportURI request host=\(ip) uri=\(SonosLog.playbackLinkValue(uri)) " +
                "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
        do {
            _ = try await soap(ip: ip, endpoint: avTransport, service: "AVTransport",
                               action: "SetAVTransportURI",
                               body: "<InstanceID>0</InstanceID>" +
                               "<CurrentURI>\(escapeXML(uri))</CurrentURI>" +
                               "<CurrentURIMetaData>\(escapeXML(metadata))</CurrentURIMetaData>")
            SonosLog.debug(
                .playbackLink,
                "SOAP SetAVTransportURI success host=\(ip) " +
                    "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "uri=\(SonosLog.playbackLinkValue(uri))")
        } catch {
            SonosLog.error(
                .playbackLink,
                "SOAP SetAVTransportURI failed host=\(ip) " +
                    "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) " +
                    "error=\(error) uri=\(SonosLog.playbackLinkValue(uri)) " +
                    "metadata=\(SonosLog.playbackMetadataSummary(metadata))")
            throw error
        }
    }

    // MARK: - Discovery

    nonisolated static func getZoneGroupState(ip: String) async throws -> [SonosPlayer] {
        let xml = try await soap(ip: ip, endpoint: zoneGroupTopology, service: "ZoneGroupTopology",
                                 action: "GetZoneGroupState", body: "")
        guard let raw = extractTag("ZoneGroupState", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)
        let grouped = parseZoneGroups(decoded)
        return grouped.isEmpty ? parseZoneMembersFlat(decoded) : grouped
    }

    nonisolated static func getDeviceName(ip: String) async throws -> String {
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)/xml/device_description.xml") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let auditStartedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            await SonosNetworkAudit.record(
                kind: .http1400,
                host: ip,
                target: "/xml/device_description.xml",
                action: "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .http((response as? HTTPURLResponse)?.statusCode))
            let xml = String(data: data, encoding: .utf8) ?? ""
            return extractTag("roomName", from: xml) ?? ip
        } catch {
            await SonosNetworkAudit.record(
                kind: .http1400,
                host: ip,
                target: "/xml/device_description.xml",
                action: "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .failure(error))
            throw error
        }
    }

    // MARK: - Speaker Grouping

    nonisolated static func joinGroup(speakerIP: String, coordinatorUUID: String) async throws {
        _ = try await soap(ip: speakerIP, endpoint: avTransport, service: "AVTransport",
                           action: "SetAVTransportURI",
                           body: "<InstanceID>0</InstanceID>" +
                           "<CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI>" +
                           "<CurrentURIMetaData></CurrentURIMetaData>")
    }

    nonisolated static func leaveGroup(speakerIP: String) async throws {
        _ = try await soap(ip: speakerIP, endpoint: avTransport, service: "AVTransport",
                           action: "BecomeCoordinatorOfStandaloneGroup",
                           body: "<InstanceID>0</InstanceID>")
    }

    // MARK: - Sonos Favorites

    /// Add an item to Sonos Favorites (FV:2) via UPnP `CreateObject`.
    ///
    /// Sonos validates the outer DIDL strictly against the inner's
    /// `upnp:class` — sending the wrong shape for the wrong type returns
    /// SOAP fault 803 with no diagnostic info. Two shapes, distinguished
    /// by caller via `rType` / `emitRes`:
    ///
    /// - **instantPlay** (albums, playlists, tracks, radio stations):
    ///   `<res protocolInfo="{scheme}:*:*:*">{uri}</res>` + real albumArt,
    ///   description usually echoes the title.
    /// - **shortcut** (artists, library folders — "bookmark" favorites):
    ///   empty `<res></res>` without `protocolInfo`, description is the
    ///   service name (e.g. "Apple Music"), albumArt is optional.
    ///
    /// Both use `<upnp:class>object.itemobject.item.sonos-favorite</upnp:class>`
    /// (the Sonos-specific class — NOT `object.item.sonos-favorite`).
    nonisolated static func addToFavorites(ip: String, title: String, uri: String,
                                            metadata: String, albumArtURI: String? = nil,
                                            rType: String = "instantPlay",
                                            description: String? = nil,
                                            emitRes: Bool = true) async throws {
        let descText = description ?? title

        var innerElements = "<dc:title>\(escapeXML(title))</dc:title>"
        innerElements += "<upnp:class>object.itemobject.item.sonos-favorite</upnp:class>"

        if emitRes {
            let scheme = uri.split(separator: ":").first.map(String.init) ?? "x-rincon-cpcontainer"
            let protocolInfo = "\(scheme):*:*:*"
            innerElements += "<res protocolInfo=\"\(protocolInfo)\">\(escapeXML(uri))</res>"
        } else {
            // Artist / collection favorites carry an empty <res></res> with no
            // protocolInfo attribute — matches the format dumped from existing
            // favorites added via the official Sonos app.
            innerElements += "<res></res>"
        }

        if let art = albumArtURI, !art.isEmpty {
            innerElements += "<upnp:albumArtURI>\(escapeXML(art))</upnp:albumArtURI>"
        }
        innerElements += "<r:type>\(rType)</r:type>"
        innerElements += "<r:description>\(escapeXML(descText))</r:description>"
        innerElements += "<r:resMD>\(escapeXML(metadata))</r:resMD>"

        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<item id=\"\" parentID=\"FV:2\" restricted=\"false\">" +
            innerElements +
            "</item></DIDL-Lite>"

        _ = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                           action: "CreateObject",
                           body: "<ContainerID>FV:2</ContainerID>" +
                           "<Elements>\(escapeXML(didl))</Elements>")
    }

    nonisolated static func removeFromFavorites(ip: String, objectId: String) async throws {
        _ = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                           action: "DestroyObject",
                           body: "<ObjectID>\(escapeXML(objectId))</ObjectID>")
    }

    // MARK: - Browse (Content Directory)

    nonisolated static func browseFavorites(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "FV:2")
    }

    nonisolated static func browsePlaylists(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "SQ:")
    }

    nonisolated static func browseRadio(ip: String) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: "R:0/0")
    }

    /// Enumerate the tracks inside a Sonos system playlist (`SQ:<n>`). The
    /// Cloud API doesn't know about these (they're local to the Sonos
    /// household), so the local playlist detail view calls UPnP directly.
    nonisolated static func browsePlaylistTracks(ip: String, playlistId: String,
                                                  start: Int = 0,
                                                  count: Int = 100) async throws -> [BrowseItem] {
        try await browseContainer(ip: ip, objectID: playlistId, start: start, count: count)
    }

    private nonisolated static func browseContainer(ip: String, objectID: String, start: Int = 0,
                                                     count: Int = 100) async throws -> [BrowseItem] {
        let body = "<ObjectID>\(escapeXML(objectID))</ObjectID>" +
            "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
            "<Filter>*</Filter>" +
            "<StartingIndex>\(start)</StartingIndex>" +
            "<RequestedCount>\(count)</RequestedCount>" +
            "<SortCriteria></SortCriteria>"
        let xml = try await soap(ip: ip, endpoint: contentDirectory, service: "ContentDirectory",
                                 action: "Browse", body: body)
        guard let result = extractTag("Result", from: xml) else { return [] }
        return parseBrowseItems(decodeXMLEntities(result), speakerIP: ip)
    }

    // MARK: - Music Services (SMAPI)

    nonisolated static func listMusicServices(ip: String) async throws -> [MusicService] {
        let endpoint = "/MusicServices/Control"
        let xml = try await soap(ip: ip, endpoint: endpoint, service: "MusicServices",
                                 action: "ListAvailableServices", body: "")
        guard let raw = extractTag("AvailableServiceDescriptorList", from: xml) else { return [] }
        let decoded = decodeXMLEntities(raw)

        // Sonos usually includes "ServiceID:ServiceType" pairs here, but SoCo
        // derives the service type from the service id because this list can be
        // incomplete on real speakers.
        var typeToId: [String: Int] = [:]
        if let typeList = extractTag("AvailableServiceTypeList", from: xml) {
            for pair in typeList.split(separator: ",") {
                let parts = pair.split(separator: ":")
                if parts.count == 2, let sid = Int(parts[0]) {
                    typeToId[String(parts[1])] = sid
                }
            }
        }

        var services = parseMusicServices(decoded)
        // Store the reverse mapping (serviceId → serviceType) on each service
        let idToType = Dictionary(typeToId.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for i in services.indices {
            services[i].serviceType = idToType[services[i].id] ?? services[i].serviceType
        }
        return services
    }

    nonisolated static func localMusicServiceAccounts(ip: String) async throws -> [LocalMusicServiceAccount] {
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)/status/accounts") else {
            throw URLError(.badURL)
        }
        let auditStartedAt = Date()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            await SonosNetworkAudit.record(
                kind: .http1400,
                host: ip,
                target: "/status/accounts",
                action: "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .http((response as? HTTPURLResponse)?.statusCode))
            let xml = String(data: data, encoding: .utf8) ?? ""
            return parseLocalMusicServiceAccounts(xml)
        } catch {
            await SonosNetworkAudit.record(
                kind: .http1400,
                host: ip,
                target: "/status/accounts",
                action: "GET",
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .failure(error))
            throw error
        }
    }

    nonisolated static func parseLocalMusicServiceAccounts(_ xml: String) -> [LocalMusicServiceAccount] {
        let accountPat = "<Account\\s([^>]*)>(.*?)</Account>"
        guard let regex = try? NSRegularExpression(pattern: accountPat, options: .dotMatchesLineSeparators) else {
            return []
        }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        return matches.compactMap { match in
            guard let attrsRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml) else { return nil }
            let attrs = String(xml[attrsRange])
            guard attr("Deleted", in: attrs) != "1",
                  let serviceType = attr("Type", in: attrs), !serviceType.isEmpty,
                  let serialNumber = attr("SerialNum", in: attrs), !serialNumber.isEmpty else {
                return nil
            }
            let body = String(xml[bodyRange])
            return LocalMusicServiceAccount(
                serviceType: serviceType,
                serialNumber: serialNumber,
                username: decodeXMLEntities(extractTag("UN", from: body) ?? ""),
                nickname: decodeXMLEntities(extractTag("NN", from: body) ?? ""))
        }
    }

    nonisolated static func inferLocalMusicServiceAccounts(
        from items: [BrowseItem],
        musicServices: [MusicService]
    ) -> [LocalMusicServiceAccount] {
        let servicesByLocalId = Dictionary(
            uniqueKeysWithValues: musicServices.map { ($0.id, $0) })
        let servicesByType = Dictionary(
            uniqueKeysWithValues: musicServices.map { ($0.serviceType, $0) })

        var accountsByKey: [String: LocalMusicServiceAccount] = [:]
        var order: [String] = []

        func add(_ service: MusicService, serialNumber: String?) {
            let serial = (serialNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard service.authType != "Anonymous",
                  !service.serviceType.isEmpty,
                  !serial.isEmpty else { return }

            let key = "\(service.serviceType)#\(serial)"
            if accountsByKey.index(forKey: key) == nil {
                order.append(key)
            }
            accountsByKey[key] = LocalMusicServiceAccount(
                serviceType: service.serviceType,
                serialNumber: serial,
                username: "X_#Svc\(service.serviceType)-\(serial)-Token",
                nickname: service.name)
        }

        for item in items {
            for blob in [item.playbackDescriptor.directURI, item.resMD, item.metaXML].compactMap({ $0 }) {
                let decoded = decodeXMLEntities(blob)
                if let sid = queryParameter("sid", in: decoded).flatMap(Int.init),
                   let service = servicesByLocalId[sid],
                   let sn = queryParameter("sn", in: decoded) {
                    add(service, serialNumber: sn)
                }

                if let serviceType = rinconServiceType(in: decoded),
                   let service = servicesByType[serviceType] {
                    add(service, serialNumber: rinconSerialNumber(in: decoded) ?? "0")
                }
            }
        }

        return order.compactMap { accountsByKey[$0] }
    }

    nonisolated static func getSessionId(ip: String, serviceId: Int) async throws -> String {
        let endpoint = "/MusicServices/Control"
        let xml = try await soap(ip: ip, endpoint: endpoint, service: "MusicServices",
                                 action: "GetSessionId",
                                 body: "<ServiceId>\(serviceId)</ServiceId><Username></Username>")
        return extractTag("SessionId", from: xml) ?? ""
    }

    nonisolated static func searchMusicService(smapiURI: String, sessionId: String, serviceId: Int,
                                                searchTerm: String, category: String = "tracks",
                                                serviceType: String? = nil,
                                                authType: String? = nil,
                                                accountSerialNumber: String? = nil,
                                                deviceId: String? = nil,
                                                count: Int = 20) async throws -> [BrowseItem] {
        guard let url = URL(string: smapiURI) else { throw URLError(.badURL) }
        let escapedTerm = escapeXML(searchTerm)
        let body = "<id>\(category)</id><term>\(escapedTerm)</term><index>0</index><count>\(count)</count>"
        let soapBody = smapiEnvelope(action: "search", body: body,
                                     sessionId: sessionId, deviceId: deviceId)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://www.sonos.com/Services/1.1#search\"", forHTTPHeaderField: "SOAPACTION")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Sonos-Session-Id")
        }
        request.httpBody = soapBody.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return parseSMAPIResults(xml, serviceId: serviceId, serviceType: serviceType,
                                 authType: authType, accountSerialNumber: accountSerialNumber)
    }

    nonisolated static func getMusicServiceMetadata(smapiURI: String, sessionId: String,
                                                     serviceId: Int, itemId: String,
                                                     serviceType: String? = nil,
                                                     authType: String? = nil,
                                                     accountSerialNumber: String? = nil,
                                                     deviceId: String? = nil,
                                                     index: Int = 0,
                                                     count: Int = 100) async throws -> [BrowseItem] {
        guard let url = URL(string: smapiURI) else { throw URLError(.badURL) }
        let escapedId = escapeXML(itemId)
        let body = "<id>\(escapedId)</id><index>\(index)</index><count>\(count)</count>"
        let soapBody = smapiEnvelope(action: "getMetadata", body: body,
                                     sessionId: sessionId, deviceId: deviceId)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"http://www.sonos.com/Services/1.1#getMetadata\"", forHTTPHeaderField: "SOAPACTION")
        if !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "X-Sonos-Session-Id")
        }
        request.httpBody = soapBody.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""
        return parseSMAPIResults(decodeXMLEntities(xml), serviceId: serviceId,
                                 serviceType: serviceType, authType: authType,
                                 accountSerialNumber: accountSerialNumber)
    }

    /// Build DIDL-Lite metadata for a streaming service track so Sonos knows
    /// which service to use when resolving the URI.
    nonisolated static func buildDIDLMetadata(item: BrowseItem) -> String {
        guard let sid = item.serviceId else { return "" }
        return buildDIDLMetadata(
            itemId: item.id, title: item.title, artist: item.artist,
            album: item.album, albumArtURL: item.albumArtURL, serviceId: sid,
            desc: "SA_RINCON\(sid)_X_#Svc\(sid)-0-Token")
    }

    nonisolated static func buildDIDLMetadata(itemId: String, title: String, artist: String,
                                              album: String, albumArtURL: String?,
                                              serviceId: Int, desc: String) -> String {
        SonosDIDLBuilder.item(
            id: itemId,
            title: title,
            upnpClass: "object.item.audioItem.musicTrack",
            creator: artist,
            album: album,
            albumArtURI: albumArtURL ?? "",
            desc: desc)
    }

    // MARK: - Retry Helper

    nonisolated static func withRetry<T>(attempts: Int = 2, _ block: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do { return try await block() }
            catch {
                lastError = error
                if attempt < attempts - 1 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    // MARK: - SOAP Internals

    private nonisolated static func soap(ip: String, endpoint: String, service: String,
                                         action: String, body: String) async throws -> String {
        let cleanIP = ip.contains(":") ? "[\(ip.split(separator: "%").first ?? Substring(ip))]" : ip
        guard let url = URL(string: "http://\(cleanIP):\(port)\(endpoint)") else {
            throw URLError(.badURL)
        }
        let longActions: Set<String> = [
            "RemoveAllTracksFromQueue",
            "AddURIToQueue",
            "AddMultipleURIsToQueue",
            "SetAVTransportURI",
            "Play"
        ]
        let timeout: TimeInterval = longActions.contains(action) ? 30 : 10
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"",
                         forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope(service: service, action: action, body: body).data(using: .utf8)

        let auditStartedAt = Date()
        do {
            let (data, urlResponse) = try await URLSession.shared.data(for: request)
            let response = String(data: data, encoding: .utf8) ?? ""
            if response.contains("<s:Fault>") || response.contains("UPnPError") {
                let code = extractTag("errorCode", from: response) ?? "?"
                let desc = extractTag("errorDescription", from: response) ?? "SOAP Fault"
                SonosLog.error(.soap, "Fault in \(action): code=\(code) desc=\(desc)")
                // Dump the raw fault body in Debug builds — Sonos sometimes embeds
                // extra context (e.g. which field failed validation) outside the
                // standard errorCode/errorDescription tags.
                SonosLog.debug(.soap, "Fault body: \(response)")
                throw NSError(domain: "SonosSOAP", code: Int(code) ?? -1,
                              userInfo: [NSLocalizedDescriptionKey: "\(action) failed: \(desc) (code \(code))"])
            }
            await SonosNetworkAudit.record(
                kind: .soap1400,
                host: ip,
                target: service,
                action: action,
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .http((urlResponse as? HTTPURLResponse)?.statusCode))
            return response
        } catch {
            await SonosNetworkAudit.record(
                kind: .soap1400,
                host: ip,
                target: service,
                action: action,
                durationMs: SonosNetworkAudit.elapsedMilliseconds(since: auditStartedAt),
                status: .failure(error))
            throw error
        }
    }

    private nonisolated static func envelope(service: String, action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="urn:schemas-upnp-org:service:\(service):1">\
        \(body)</u:\(action)></s:Body></s:Envelope>
        """
    }

    // MARK: - XML Helpers

    nonisolated static func extractTag(_ tag: String, from xml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)(?:\\s[^>]*)?>(.*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }

    nonisolated static func decodeXMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private nonisolated static func attr(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private nonisolated static func queryParameter(_ name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:[?&]|&amp;)\(escaped)=([^&\\s\"<>]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).removingPercentEncoding ?? String(text[range])
    }

    private nonisolated static func rinconServiceType(in text: String) -> String? {
        let pattern = "SA_RINCON(\\d+)_"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private nonisolated static func rinconSerialNumber(in text: String) -> String? {
        let pattern = "#Svc\\d+-(.*?)-Token"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - Zone Group Parsing (with group info)

    private nonisolated static func parseZoneGroups(_ xml: String) -> [SonosPlayer] {
        let groupPat = "<ZoneGroup\\s[^>]*Coordinator=\"([^\"]*)\"[^>]*ID=\"([^\"]*)\"[^>]*>(.*?)</ZoneGroup>"
        guard let groupRx = try? NSRegularExpression(pattern: groupPat, options: .dotMatchesLineSeparators) else { return [] }
        let groupMatches = groupRx.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        var players: [SonosPlayer] = []

        for gm in groupMatches {
            guard let coordRange = Range(gm.range(at: 1), in: xml),
                  let idRange = Range(gm.range(at: 2), in: xml),
                  let bodyRange = Range(gm.range(at: 3), in: xml) else { continue }

            let coordUUID = String(xml[coordRange])
            let groupId = String(xml[idRange])
            let body = String(xml[bodyRange])

            var members: [(uuid: String, name: String, ip: String, invisible: Bool)] = []
            var coordIP: String?

            let memberPat = "<ZoneGroupMember[^>]*?(?:/>|>)"
            guard let memberRx = try? NSRegularExpression(pattern: memberPat, options: .dotMatchesLineSeparators) else { continue }
            for mm in memberRx.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let r = Range(mm.range, in: body) else { continue }
                let tag = String(body[r])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                let invisible = attr("Invisible", in: tag) == "1"
                if let url = URL(string: location), let host = url.host {
                    members.append((uuid, name, host, invisible))
                    if uuid == coordUUID { coordIP = host }
                }
            }

            for m in members {
                let isCoord = m.uuid == coordUUID
                players.append(SonosPlayer(
                    id: m.uuid, name: m.name, ipAddress: m.ip,
                    isCoordinator: isCoord, groupId: groupId,
                    coordinatorIP: isCoord ? nil : coordIP,
                    isInvisible: m.invisible
                ))
            }
        }
        return players
    }

    private nonisolated static func parseZoneMembersFlat(_ xml: String) -> [SonosPlayer] {
        let patterns = ["<ZoneGroupMember[^/]*?/>", "<ZoneGroupMember[^>]*?>"]
        for pat in patterns {
            guard let regex = try? NSRegularExpression(pattern: pat, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            var players: [SonosPlayer] = []
            for match in matches {
                guard let range = Range(match.range, in: xml) else { continue }
                let tag = String(xml[range])
                let uuid = attr("UUID", in: tag) ?? UUID().uuidString
                let name = attr("ZoneName", in: tag) ?? "Unknown"
                let location = attr("Location", in: tag) ?? ""
                if let url = URL(string: location), let host = url.host {
                    players.append(SonosPlayer(id: uuid, name: name, ipAddress: host, isCoordinator: true))
                }
            }
            if !players.isEmpty { return players }
        }
        return []
    }

    // MARK: - Queue Parsing

    private nonisolated static func parseQueueItems(_ xml: String, speakerIP: String) -> [QueueItem] {
        let itemPat = "<item\\s([^>]*)>(.*?)</item>"
        guard let regex = try? NSRegularExpression(pattern: itemPat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.enumerated().compactMap { idx, match in
            guard let attrRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml) else { return nil }
            let attrs = String(xml[attrRange])
            let item = String(xml[bodyRange])
            let objectID = attr("id", in: attrs) ?? "Q:0/\(idx)"

            let title = decodeXMLEntities(extractTag("dc:title", from: item) ?? "Unknown")
            let artist = decodeXMLEntities(extractTag("dc:creator", from: item) ?? extractTag("upnp:artist", from: item) ?? "Unknown")
            let album = decodeXMLEntities(extractTag("upnp:album", from: item) ?? "")
            let uri = extractTag("res", from: item).map { decodeXMLEntities($0) }
            var art: String?
            if let p = extractTag("upnp:albumArtURI", from: item) {
                var decoded = decodeXMLEntities(p)
                if decoded.contains("%25") {
                    decoded = decoded.removingPercentEncoding ?? decoded
                }
                art = decoded.hasPrefix("http") ? decoded : "http://\(speakerIP):\(port)\(decoded)"
            }

            let fullTag = Range(match.range, in: xml).map { String(xml[$0]) }
            return QueueItem(id: "\(idx)", objectID: objectID, trackNumber: idx + 1,
                             title: title, artist: artist, album: album, albumArtURL: art,
                             uri: uri, metaXML: fullTag)
        }
    }

    // MARK: - Browse Parsing

    private nonisolated static func parseBrowseItems(_ xml: String, speakerIP: String) -> [BrowseItem] {
        let containerPat = "<container\\s([^>]*)>(.*?)</container>"
        let itemPat = "<item\\s([^>]*)>(.*?)</item>"

        var results: [BrowseItem] = []

        for (pattern, isContainer) in [(containerPat, true), (itemPat, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { continue }
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                guard let attrRange = Range(match.range(at: 1), in: xml),
                      let bodyRange = Range(match.range(at: 2), in: xml) else { continue }
                let attrs = String(xml[attrRange])
                let body = String(xml[bodyRange])
                let itemID = attr("id", in: attrs) ?? UUID().uuidString

                let title = decodeXMLEntities(extractTag("dc:title", from: body) ?? "Unknown")
                let artist = decodeXMLEntities(extractTag("dc:creator", from: body) ?? extractTag("upnp:artist", from: body) ?? "")
                let album = decodeXMLEntities(extractTag("upnp:album", from: body) ?? "")
                let uri = extractTag("res", from: body).map { decodeXMLEntities($0) }
                var art: String?
                if let p = extractTag("upnp:albumArtURI", from: body) {
                    var decoded = decodeXMLEntities(p)
                    if decoded.contains("%25") { decoded = decoded.removingPercentEncoding ?? decoded }
                    art = decoded.hasPrefix("http") ? decoded : "http://\(speakerIP):\(port)\(decoded)"
                }

                // Extract r:resMD (resource metadata for Favorites)
                var resMD: String?
                if let rawMD = extractTag("r:resMD", from: body) {
                    resMD = decodeXMLEntities(rawMD)
                }

                // If main <res> is missing, try to extract URI from resMD
                var finalURI = uri
                if (finalURI == nil || finalURI?.isEmpty == true), let md = resMD {
                    finalURI = extractTag("res", from: md).map { decodeXMLEntities($0) }
                }

                // Detect container-like URIs even when stored as <item> in Favorites
                let effectiveContainer = isContainer ||
                    (finalURI?.contains("x-rincon-cpcontainer:") == true)

                let fullTag = Range(match.range, in: xml).map { String(xml[$0]) }
                results.append(BrowseItem(id: itemID, title: title, artist: artist, album: album,
                                          albumArtURL: art, uri: finalURI, metaXML: fullTag,
                                          resMD: resMD, isContainer: effectiveContainer))
            }
        }
        return results
    }

    // MARK: - SMAPI Parsing

    private nonisolated static func parseSMAPIResults(_ xml: String, serviceId: Int,
                                                       serviceType: String? = nil,
                                                       authType: String? = nil,
                                                       accountSerialNumber: String? = nil) -> [BrowseItem] {
        let itemPat = "<mediaMetadata[^>]*>(.*?)</mediaMetadata>"
        guard let regex = try? NSRegularExpression(pattern: itemPat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            let body = String(xml[range])
            let id = extractTag("id", from: body) ?? UUID().uuidString
            let title = decodeXMLEntities(extractTag("title", from: body) ?? "Unknown")
            let artist = decodeXMLEntities(extractTag("artist", from: body) ?? "")
            let album = decodeXMLEntities(extractTag("album", from: body) ?? "")
            let art = extractTag("albumArtURI", from: body)
            let uri = extractTag("trackUri", from: body) ?? extractTag("uri", from: body)
            let duration = extractTag("duration", from: body).flatMap(TimeInterval.init) ?? 0
            let metadata = buildSMAPIDIDLMetadata(
                itemId: id,
                title: title,
                artist: artist,
                album: album,
                albumArtURL: art,
                uri: uri,
                serviceType: serviceType ?? String(serviceId * 256 + 7),
                authType: authType,
                accountSerialNumber: accountSerialNumber,
                isContainer: false)

            return BrowseItem(id: id, title: title, artist: artist, album: album,
                              albumArtURL: art, uri: uri, metaXML: nil, duration: duration,
                              resMD: metadata, isContainer: false,
                              serviceId: serviceId)
        }
    }

    private nonisolated static func smapiEnvelope(action: String, body: String,
                                                  sessionId: String,
                                                  deviceId: String?) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        \(smapiHeader(sessionId: sessionId, deviceId: deviceId))\
        <s:Body><\(action) xmlns="http://www.sonos.com/Services/1.1">\
        \(body)</\(action)></s:Body></s:Envelope>
        """
    }

    private nonisolated static func smapiHeader(sessionId: String, deviceId: String?) -> String {
        let cleanDeviceId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sessionId.isEmpty || !cleanDeviceId.isEmpty else { return "" }
        var credentials = "<credentials xmlns=\"http://www.sonos.com/Services/1.1\">"
        if !sessionId.isEmpty {
            credentials += "<sessionId>\(escapeXML(sessionId))</sessionId>"
        }
        if !cleanDeviceId.isEmpty {
            credentials += "<deviceId>\(escapeXML(cleanDeviceId))</deviceId>"
        }
        credentials += "<deviceProvider>Sonos</deviceProvider></credentials>"
        return "<s:Header>\(credentials)</s:Header>"
    }

    private nonisolated static func buildSMAPIDIDLMetadata(itemId: String,
                                                           title: String,
                                                           artist: String,
                                                           album: String,
                                                           albumArtURL: String?,
                                                           uri: String?,
                                                           serviceType: String,
                                                           authType: String?,
                                                           accountSerialNumber: String?,
                                                           isContainer: Bool) -> String {
        let escapedId = itemId.replacingOccurrences(of: ":", with: "%3a")
        let didlId = escapedId.hasPrefix("0fffffff") ? escapedId : "0fffffff\(escapedId)"
        let desc = smapiDescriptor(serviceType: serviceType, authType: authType,
                                   accountSerialNumber: accountSerialNumber)
        let tag = isContainer ? "container" : "item"
        let upnpClass = isContainer ? "object.container" : "object.item.audioItem.musicTrack"
        let resources: [SonosDIDLResource]
        if let uri, !uri.isEmpty {
            resources = [SonosDIDLResource(uri: uri, protocolInfo: "DUMMY")]
        } else {
            resources = []
        }
        return SonosDIDLBuilder.document([
            SonosDIDLElement(
                tag: tag,
                id: didlId,
                title: title,
                upnpClass: upnpClass,
                resources: resources,
                creator: artist.isEmpty ? nil : artist,
                album: album.isEmpty ? nil : album,
                albumArtist: artist.isEmpty ? nil : artist,
                albumArtURI: (albumArtURL?.isEmpty == false) ? albumArtURL : nil,
                desc: desc)
        ])
    }

    private nonisolated static func smapiDescriptor(serviceType: String,
                                                    authType: String?,
                                                    accountSerialNumber: String?) -> String {
        if authType == "Anonymous" {
            return "SA_RINCON\(serviceType)_"
        }
        let serial = accountSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenSerial = (serial?.isEmpty == false) ? serial! : "0"
        return "SA_RINCON\(serviceType)_X_#Svc\(serviceType)-\(tokenSerial)-Token"
    }

    // MARK: - Music Service Parsing

    nonisolated static func parseMusicServices(_ xml: String) -> [MusicService] {
        let pat = "<Service[^>]*?(?:/>|>(.*?)</Service>)"
        guard let regex = try? NSRegularExpression(pattern: pat, options: .dotMatchesLineSeparators) else { return [] }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        return matches.compactMap { match in
            guard let fullRange = Range(match.range, in: xml) else { return nil }
            let tag = String(xml[fullRange])
            guard let idStr = attr("Id", in: tag), let id = Int(idStr) else { return nil }
            let name = attr("Name", in: tag) ?? "Unknown"
            let smapiURI = attr("SecureUri", in: tag) ?? attr("Uri", in: tag) ?? ""
            let caps = Int(attr("Capabilities", in: tag) ?? "0") ?? 0
            let auth = attr("Auth", in: tag) ?? "Anonymous"
            guard !smapiURI.isEmpty else { return nil }
            let serviceType = String(id * 256 + 7)
            return MusicService(
                id: id,
                name: name,
                smapiURI: smapiURI,
                capabilitiesMask: caps,
                authType: auth,
                serviceType: serviceType,
                manifestURI: attr("ManifestUri", in: tag),
                presentationMapURI: attr("PresentationMapUri", in: tag))
        }
    }

    // MARK: - Audio Quality Parsing

    private nonisolated static func parseAudioQuality(from meta: String, source: PlaybackSource) -> AudioQuality? {
        let resPat = "<res\\s([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: resPat, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: meta, range: NSRange(meta.startIndex..., in: meta)),
              let range = Range(match.range(at: 1), in: meta) else { return nil }
        let attrs = String(meta[range])

        guard let proto = attr("protocolInfo", in: attrs) else { return nil }
        let sr = attr("sampleFrequency", in: attrs)
        let bd = attr("bitsPerSample", in: attrs)
        let ch = attr("nrAudioChannels", in: attrs)
        let streamContent = extractTag("r:streamContent", from: meta) ?? ""

        return AudioQuality.from(protocolInfo: proto, sampleRate: sr, bitDepth: bd,
                                 channels: ch, streamContent: streamContent, source: source)
    }

    // MARK: - XML Escape

    nonisolated static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }
}
