import Foundation

/// A desktop signed into the user's Dimo account, as listed by the account host directory.
public struct AccountDesktop: Identifiable, Equatable, Sendable {
    public let hostId: String
    public let name: String
    public let osType: String?
    public let osArch: String?
    public let lastSeenAt: String?
    public var cloudOnline: Bool

    public var id: String { hostId }

    public init(
        hostId: String,
        name: String,
        osType: String?,
        osArch: String?,
        lastSeenAt: String?,
        cloudOnline: Bool = false
    ) {
        self.hostId = hostId
        self.name = name
        self.osType = osType
        self.osArch = osArch
        self.lastSeenAt = lastSeenAt
        self.cloudOnline = cloudOnline
    }

    public static func isGenericName(_ raw: String) -> Bool {
        let cleaned = raw
            .replacingOccurrences(of: ".local", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch cleaned {
        case "",
             "local host",
             "localhost",
             "vibex 电脑",
             "vibex 桌面端",
             "dimo 电脑",
             "dimo 桌面端",
             "vibex desktop",
             "dimo desktop":
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        let cleaned = name
            .replacingOccurrences(of: ".local", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isGenericName(cleaned) {
            switch osBadge {
            case "macOS": return "Dimo 桌面端 (Mac)"
            case "Windows": return "Dimo 桌面端 (Windows)"
            case "Linux": return "Dimo 桌面端 (Linux)"
            default: return "Dimo 桌面端"
            }
        }
        return cleaned
    }

    public var osBadge: String? {
        let os = (osType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch os.lowercased() {
        case "": return nil
        case "macos", "darwin": return "macOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return os
        }
    }

    public var osArchBadge: String? {
        let arch = (osArch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (osBadge, arch.isEmpty ? nil : arch) {
        case let (os?, arch?): return "\(os) · \(arch)"
        case let (os?, nil): return os
        case let (nil, arch?): return arch
        case (nil, nil): return nil
        }
    }

    /// Relay tenant origin through which the cloud service reaches this desktop.
    public func cloudOrigin(relayBase: String) -> String {
        var base = relayBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/t/\(hostId)"
    }

    /// The account directory prefixes host ids with `host:`; Host APIs and LAN health use the bare id.
    public static func rawHostId(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("host:") else { return trimmed }
        return String(trimmed.dropFirst("host:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let nonConnectableHostIds: Set<String> = [
        "local-desktop",
        "remote-desktop",
        "default",
        "localhost",
    ]

    private static let nonConnectableHostPrefixes: [String] = [
        "session:",
        "web:",
        "profile:",
        "origin:",
    ]

    private static func isConnectableHostId(_ bareHostId: String) -> Bool {
        let lower = bareHostId.lowercased()
        guard !lower.isEmpty else { return false }
        if nonConnectableHostIds.contains(lower) { return false }
        if nonConnectableHostPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
        return true
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Desktops in a `GET /api/account/desktop/host-configs` response: `hosts` ∪ `records`, local kind only,
    /// skipping non-connectable placeholders, deduplicated by raw host id, most recently seen first.
    public static func parseDirectory(_ data: Data) -> [AccountDesktop] {
        struct Snapshot: Decodable {
            let hostId: String?
            let hostName: String?
            let kind: String?
            let osType: String?
            let osArch: String?
            let updatedAt: String?
            let lastSeenAt: String?
        }
        struct Entry: Decodable {
            let hostId: String?
            let hostName: String?
            let kind: String?
            let osType: String?
            let osArch: String?
            let updatedAt: String?
            let lastSeenAt: String?
            let snapshot: Snapshot?
        }
        struct Directory: Decodable {
            let hosts: [Entry]?
            let records: [Entry]?
        }
        guard let directory = try? JSONDecoder().decode(Directory.self, from: data) else { return [] }

        var order: [String] = []
        var byId: [String: AccountDesktop] = [:]
        for entry in (directory.hosts ?? []) + (directory.records ?? []) {
            let snap = entry.snapshot
            let kind = nonEmpty(entry.kind) ?? nonEmpty(snap?.kind) ?? "local"
            // Records without a kind come from desktops that predate host kinds, which were all local.
            guard kind == "local" else { continue }
            let rawIdSource = nonEmpty(entry.hostId) ?? nonEmpty(snap?.hostId) ?? ""
            let hostId = rawHostId(rawIdSource)
            guard isConnectableHostId(hostId) else { continue }
            let seenAt = [entry.lastSeenAt, entry.updatedAt, snap?.lastSeenAt, snap?.updatedAt]
                .compactMap(nonEmpty)
                .max()
            let name = nonEmpty(entry.hostName) ?? nonEmpty(snap?.hostName) ?? ""
            let osType = nonEmpty(entry.osType) ?? nonEmpty(snap?.osType)
            let osArch = nonEmpty(entry.osArch) ?? nonEmpty(snap?.osArch)
            guard let existing = byId[hostId] else {
                order.append(hostId)
                byId[hostId] = AccountDesktop(
                    hostId: hostId,
                    name: name,
                    osType: osType,
                    osArch: osArch,
                    lastSeenAt: seenAt
                )
                continue
            }
            let mergedName: String
            if existing.name.isEmpty || (isGenericName(existing.name) && !name.isEmpty && !isGenericName(name)) {
                mergedName = name
            } else {
                mergedName = existing.name
            }
            byId[hostId] = AccountDesktop(
                hostId: hostId,
                name: mergedName,
                osType: nonEmpty(existing.osType) ?? osType,
                osArch: nonEmpty(existing.osArch) ?? osArch,
                lastSeenAt: [existing.lastSeenAt, seenAt].compactMap { $0 }.max()
            )
        }
        let desktops = order.compactMap { byId[$0] }
        return desktops.enumerated().sorted { lhs, rhs in
            let left = lhs.element.lastSeenAt ?? ""
            let right = rhs.element.lastSeenAt ?? ""
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    /// Collapses offline ghost installs that share a generic host name and platform `(osType, osArch)` while
    /// preserving all online desktops and custom-named desktops, sorted online first, then paired, then most recent.
    public static func deduplicate(
        _ desktops: [AccountDesktop],
        onlineLanHostIds: Set<String> = [],
        pairedHostIds: Set<String> = []
    ) -> [AccountDesktop] {
        struct PlatformKey: Hashable {
            let os: String
            let arch: String
        }
        let onlineSet = Set(onlineLanHostIds.map { rawHostId($0).lowercased() })
        let pairedSet = Set(pairedHostIds.map { rawHostId($0).lowercased() })

        func isOnline(_ desktop: AccountDesktop) -> Bool {
            desktop.cloudOnline || onlineSet.contains(desktop.hostId.lowercased())
        }
        func isPaired(_ desktop: AccountDesktop) -> Bool {
            pairedSet.contains(desktop.hostId.lowercased())
        }
        func platformKey(for desktop: AccountDesktop) -> PlatformKey {
            let rawOs = (desktop.osType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let os = rawOs == "darwin" ? "macos" : rawOs
            let rawArch = (desktop.osArch ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let arch: String
            switch rawArch {
            case "arm64": arch = "aarch64"
            case "amd64": arch = "x86_64"
            default: arch = rawArch
            }
            return PlatformKey(os: os, arch: arch)
        }

        var survivors: [(offset: Int, desktop: AccountDesktop)] = []
        var genericGroups: [PlatformKey: [(offset: Int, desktop: AccountDesktop)]] = [:]
        var genericOrder: [PlatformKey] = []

        for (offset, desktop) in desktops.enumerated() {
            if isGenericName(desktop.name) {
                let key = platformKey(for: desktop)
                if genericGroups[key] == nil {
                    genericOrder.append(key)
                }
                genericGroups[key, default: []].append((offset, desktop))
            } else {
                survivors.append((offset, desktop))
            }
        }

        for key in genericOrder {
            guard let members = genericGroups[key], !members.isEmpty else { continue }
            let onlineMembers = members.filter { isOnline($0.desktop) }
            if !onlineMembers.isEmpty {
                survivors.append(contentsOf: onlineMembers)
                continue
            }
            let pairedMembers = members.filter { isPaired($0.desktop) }
            let pool = pairedMembers.isEmpty ? members : pairedMembers
            if let mostRecent = pool.min(by: { lhs, rhs in
                let leftSeen = lhs.desktop.lastSeenAt ?? ""
                let rightSeen = rhs.desktop.lastSeenAt ?? ""
                if leftSeen != rightSeen { return leftSeen > rightSeen }
                return lhs.offset < rhs.offset
            }) {
                survivors.append(mostRecent)
            }
        }

        return survivors.sorted { lhs, rhs in
            let leftOnline = isOnline(lhs.desktop)
            let rightOnline = isOnline(rhs.desktop)
            if leftOnline != rightOnline { return leftOnline && !rightOnline }

            let leftPaired = isPaired(lhs.desktop)
            let rightPaired = isPaired(rhs.desktop)
            if leftPaired != rightPaired { return leftPaired && !rightPaired }

            let leftSeen = lhs.desktop.lastSeenAt ?? ""
            let rightSeen = rhs.desktop.lastSeenAt ?? ""
            if leftSeen != rightSeen { return leftSeen > rightSeen }

            return lhs.offset < rhs.offset
        }.map(\.desktop)
    }
}
