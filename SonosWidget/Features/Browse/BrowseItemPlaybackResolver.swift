import Foundation

struct BrowseItemPlaybackResolver: Sendable {
    struct CloudIds: Equatable, Sendable {
        let objectId: String
        let cloudServiceId: String
        let accountId: String
    }

    struct ServiceParams: Equatable, Sendable {
        let sid: String
        let flags: String
        let sn: String
    }

    let cloudToLocalSid: [String: Int]
    let localToCloudSid: [Int: String]
    let musicServices: [MusicService]

    func parseCloudIds(from item: BrowseItem) -> CloudIds? {
        let uriSource = item.playbackDescriptor.directURI
            ?? item.resMD.flatMap { SonosAPI.extractTag("res", from: $0) }

        if let uri = uriSource,
           let result = parseCloudIds(fromURI: uri) {
            return result
        }

        return parseCloudIdsFromDIDLMetadata(item)
    }

    func serviceParams(from items: [BrowseItem]) -> ServiceParams? {
        for item in items {
            guard let uri = item.playbackDescriptor.directURI,
                  uri.contains("sid="),
                  uri.contains("sn=") else { continue }

            let query = queryParameters(from: uri)
            guard let sid = query["sid"], let sn = query["sn"] else { continue }
            return ServiceParams(
                sid: sid,
                flags: query["flags"] ?? "8300",
                sn: sn
            )
        }
        return nil
    }

    func favoriteTransportURI(
        resMD: String,
        seedItems: [BrowseItem],
        defaultFlags: Int
    ) -> String? {
        guard let itemId = extractItemId(from: resMD) else { return nil }

        var flags = defaultFlags
        if itemId.count >= 8 {
            let start = itemId.index(itemId.startIndex, offsetBy: 4)
            let end = itemId.index(itemId.startIndex, offsetBy: 8)
            flags = Int(String(itemId[start..<end]), radix: 16) ?? defaultFlags
        }

        guard let params = serviceParams(from: seedItems) else {
            return "x-rincon-cpcontainer:\(itemId)"
        }

        return "x-rincon-cpcontainer:\(itemId)?sid=\(params.sid)&flags=\(flags)&sn=\(params.sn)"
    }

    private func parseCloudIds(fromURI uri: String) -> CloudIds? {
        let query = queryParameters(from: uri)
        guard let sid = query["sid"],
              let accountId = query["sn"],
              let cloudSid = localToCloudSid[Int(sid) ?? 0] else {
            return nil
        }

        let objectId = extractObjectId(fromURI: uri)
        guard !objectId.isEmpty else { return nil }
        return CloudIds(objectId: objectId, cloudServiceId: cloudSid, accountId: accountId)
    }

    private func queryParameters(from uri: String) -> [String: String] {
        guard let queryPart = uri.split(separator: "?", maxSplits: 1).last else { return [:] }
        var result: [String: String] = [:]
        for param in queryPart.split(separator: "&") {
            let kv = param.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[String(kv[0])] = String(kv[1])
        }
        return result
    }

    private func extractObjectId(fromURI uri: String) -> String {
        let pathPart = uri.split(separator: "?").first.map(String.init) ?? uri
        var objectId: String
        if let colonRange = pathPart.range(of: ":", options: .backwards) {
            let afterScheme = String(pathPart[colonRange.upperBound...])
            if afterScheme.count > 8,
               afterScheme.prefix(8).allSatisfy({ $0.isHexDigit }) {
                objectId = String(afterScheme.dropFirst(8))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                objectId = afterScheme
            }
        } else {
            objectId = pathPart
        }

        if objectId.contains("%25") {
            objectId = objectId.removingPercentEncoding ?? objectId
        }
        return objectId
    }

    private func parseCloudIdsFromDIDLMetadata(_ item: BrowseItem) -> CloudIds? {
        let xmlSources = [item.resMD, item.metaXML].compactMap { $0 }
        guard !xmlSources.isEmpty else { return nil }

        var cloudServiceId: String?
        var extractedSn: String?
        for xml in xmlSources {
            if let binding = rinconBindingAndAccountSn(in: xml) {
                cloudServiceId = binding.cloudServiceId
                extractedSn = binding.accountId
                break
            }
        }

        guard let cloudSid = cloudServiceId else { return nil }

        var objectId: String?
        for xml in xmlSources {
            guard let idVal = extractDIDLItemId(from: xml),
                  idVal.count > 8,
                  idVal.prefix(8).allSatisfy({ $0.isHexDigit }) else {
                continue
            }
            var oid = String(idVal.dropFirst(8))
            if oid.contains("%25") {
                oid = oid.removingPercentEncoding ?? oid
            }
            if !oid.isEmpty {
                objectId = oid
                break
            }
        }

        guard let objectId else { return nil }
        return CloudIds(
            objectId: objectId,
            cloudServiceId: cloudSid,
            accountId: extractedSn ?? "2"
        )
    }

    private func rinconBindingAndAccountSn(in xml: String) -> (localSid: Int, cloudServiceId: String, accountId: String?)? {
        let region: String = {
            if let desc = SonosAPI.extractTag("desc", from: xml),
               desc.contains("SA_RINCON") {
                return desc
            }
            return xml
        }()

        guard let range = region.range(of: "SA_RINCON(\\d+)_", options: .regularExpression) else {
            return nil
        }
        let token = String(region[range])
        guard token.hasPrefix("SA_RINCON"), token.hasSuffix("_") else { return nil }
        let digits = String(token.dropFirst("SA_RINCON".count).dropLast(1))
        guard let pair = localAndCloudServiceIds(fromRinconDigits: digits) else { return nil }
        let sn = extractSnFromSvcLine(in: region) ?? extractSnFromSvcLine(in: xml)
        return (pair.localSid, pair.cloudServiceId, sn)
    }

    private func localAndCloudServiceIds(fromRinconDigits digits: String) -> (localSid: Int, cloudServiceId: String)? {
        if let n = Int(digits), let cloud = localToCloudSid[n] {
            return (n, cloud)
        }
        if let local = cloudToLocalSid[digits] {
            return (local, localToCloudSid[local] ?? digits)
        }
        if let local = canonicalLocalSid(forCloudOrServiceTypeDigits: digits),
           let cloud = localToCloudSid[local] {
            return (local, cloud)
        }
        return nil
    }

    private func canonicalLocalSid(forCloudOrServiceTypeDigits digits: String) -> Int? {
        if let localSid = cloudToLocalSid[digits] { return localSid }
        if let match = musicServices.first(where: { $0.serviceType == digits }) {
            return match.id
        }
        return nil
    }

    private func extractSnFromSvcLine(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "#Svc\\d+-([^-]+)-"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func extractDIDLItemId(from xml: String) -> String? {
        let pattern = "<(?:item|container)\\s+id=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private func extractItemId(from resMD: String) -> String? {
        let pattern = #"<item\s+id="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: resMD, range: NSRange(resMD.startIndex..., in: resMD)),
              let range = Range(match.range(at: 1), in: resMD) else {
            return nil
        }
        return String(resMD[range])
    }
}
