import Foundation
import Testing
@testable import CompanionCore

@Test func accountDirectoryListsLocalDesktopsOnce() {
    let json = """
{
"hosts": [
{"hostId":"host:abc","hostName":"MacBook-Pro.local","kind":"local","osType":"macos","osArch":"arm64","agents":[],"updatedAt":"2026-11-01T08:00:00Z"},
{"hostId":"host:ssh1","hostName":"build-box","kind":"ssh","osType":"linux","osArch":"x86_64","agents":[],"updatedAt":"2026-11-10T08:00:00Z"},
{"hostId":"host:web1","hostName":"Browser","kind":"web","osType":"","osArch":"","agents":[],"updatedAt":"2026-11-10T08:00:00Z"}
],
"records": [
{"hostId":"host:abc","hostName":"MacBook-Pro","kind":"local","osType":"macos","osArch":"arm64","lastSeenAt":"2026-11-11T09:00:00Z","configSynced":true},
{"hostId":"host:win","hostName":"Office-PC","kind":"local","osType":"windows","osArch":"x86_64","lastSeenAt":"2026-11-05T09:00:00Z","configSynced":false},
{"hostId":"host:old","hostName":"Legacy","osType":"linux","osArch":"x86_64","lastSeenAt":"2026-10-01T09:00:00Z","configSynced":false},
{"hostId":"host:","hostName":"Empty","kind":"local","lastSeenAt":"2026-11-12T09:00:00Z","configSynced":false}
]
}
"""
    let desktops = AccountDesktop.parseDirectory(Data(json.utf8))
    #expect(desktops.map(\.hostId) == ["abc", "win", "old"])
    #expect(desktops[0].displayName == "MacBook-Pro")
    #expect(desktops[0].lastSeenAt == "2026-11-11T09:00:00Z")
    #expect(desktops[0].osBadge == "macOS")
    #expect(desktops[1].osBadge == "Windows")
}

@Test func accountDirectorySkipsDeviceLoginsAndPlaceholders() {
    let json = """
{"hosts":[
{"hostId":"host:local-desktop","hostName":"Local Host","kind":"local","osType":"macos","osArch":"aarch64","updatedAt":"2026-11-12T12:00:00Z"},
{"hostId":"host:remote-desktop","hostName":"Local Host","kind":"local","osType":"macos","osArch":"aarch64","updatedAt":"2026-11-12T12:00:00Z"},
{"hostId":"host:default","hostName":"Local Host","kind":"local","updatedAt":"2026-11-12T12:00:00Z"},
{"hostId":"host:localhost","hostName":"localhost","kind":"local","updatedAt":"2026-11-12T12:00:00Z"}
],"records":[
{"hostId":"session:42","hostName":"iPhone","kind":"local","lastSeenAt":"2026-11-12T11:00:00Z","configSynced":false},
{"hostId":"web:tab-1","hostName":"Browser","kind":"local","lastSeenAt":"2026-11-12T11:00:00Z","configSynced":false},
{"hostId":"profile:dev-1","hostName":"Profile","kind":"local","lastSeenAt":"2026-11-12T11:00:00Z","configSynced":false},
{"hostId":"origin:http://127.0.0.1:17891","hostName":"Origin","kind":"local","lastSeenAt":"2026-11-12T11:00:00Z","configSynced":false},
{"hostId":"host:mac","hostName":"Mac","kind":"local","lastSeenAt":"2026-11-12T10:00:00Z","configSynced":true}
]}
"""
    #expect(AccountDesktop.parseDirectory(Data(json.utf8)).map(\.hostId) == ["mac"])
}

@Test func accountDesktopFriendlyDisplayNameAndArchBadge() {
    let macGeneric = AccountDesktop(hostId: "m1", name: "Local Host", osType: "macos", osArch: "aarch64", lastSeenAt: nil)
    #expect(macGeneric.displayName == "Dimo 桌面端 (Mac)")
    #expect(macGeneric.osBadge == "macOS")
    #expect(macGeneric.osArchBadge == "macOS · aarch64")

    let winGeneric = AccountDesktop(hostId: "w1", name: "VibeX 桌面端", osType: "windows", osArch: "x86_64", lastSeenAt: nil)
    #expect(winGeneric.displayName == "Dimo 桌面端 (Windows)")

    let linuxGeneric = AccountDesktop(hostId: "l1", name: "localhost.local", osType: "linux", osArch: "x86_64", lastSeenAt: nil)
    #expect(linuxGeneric.displayName == "Dimo 桌面端 (Linux)")

    let unknownGeneric = AccountDesktop(hostId: "u1", name: "", osType: nil, osArch: nil, lastSeenAt: nil)
    #expect(unknownGeneric.displayName == "Dimo 桌面端")
    #expect(unknownGeneric.osArchBadge == nil)

    let custom = AccountDesktop(hostId: "c1", name: "Studio-Max.local", osType: "macos", osArch: "arm64", lastSeenAt: nil)
    #expect(custom.displayName == "Studio-Max")
    #expect(custom.osArchBadge == "macOS · arm64")
}

@Test func accountDesktopDeduplicatesGenericGhostInstalls() {
    let ghostOld = AccountDesktop(
        hostId: "uuid-old-vibex",
        name: "Local Host",
        osType: "macos",
        osArch: "aarch64",
        lastSeenAt: "2026-10-01T08:00:00Z",
        cloudOnline: false
    )
    let liveDimo = AccountDesktop(
        hostId: "uuid-live-dimo",
        name: "Local Host",
        osType: "macos",
        osArch: "aarch64",
        lastSeenAt: "2026-11-18T08:00:00Z",
        cloudOnline: true
    )
    let newerOfflineGhost = AccountDesktop(
        hostId: "uuid-reinstall",
        name: "Local Host",
        osType: "macos",
        osArch: "aarch64",
        lastSeenAt: "2026-11-19T08:00:00Z",
        cloudOnline: false
    )

    // 1. Prefers cloudOnline == true over offline ghosts even if an offline ghost has a newer timestamp
    let withOnline = AccountDesktop.deduplicate([newerOfflineGhost, ghostOld, liveDimo])
    #expect(withOnline.map(\.hostId) == ["uuid-live-dimo"])

    // 2. When all are offline, falls back to latest lastSeenAt (or pairedHostIds when present)
    var offlineCopy = liveDimo
    offlineCopy.cloudOnline = false
    let allOffline = AccountDesktop.deduplicate([ghostOld, offlineCopy, newerOfflineGhost])
    #expect(allOffline.map(\.hostId) == ["uuid-reinstall"])

    let pairedPreferred = AccountDesktop.deduplicate(
        [ghostOld, offlineCopy, newerOfflineGhost],
        pairedHostIds: ["uuid-live-dimo"]
    )
    #expect(pairedPreferred.map(\.hostId) == ["uuid-live-dimo"])

    // 3. Keeps custom-named desktops and sorts online -> paired -> lastSeenAt desc
    let customOffline = AccountDesktop(
        hostId: "uuid-office",
        name: "Office-iMac",
        osType: "macos",
        osArch: "aarch64",
        lastSeenAt: "2026-11-19T09:00:00Z",
        cloudOnline: false
    )
    let mixed = AccountDesktop.deduplicate([customOffline, newerOfflineGhost, liveDimo])
    #expect(mixed.map(\.hostId) == ["uuid-live-dimo", "uuid-office"])
}

@Test func accountDirectoryToleratesMissingLists() {
    #expect(AccountDesktop.parseDirectory(Data("{}".utf8)).isEmpty)
    #expect(AccountDesktop.parseDirectory(Data("not json".utf8)).isEmpty)
}

@Test func accountDesktopBuildsRelayTenantOrigin() {
    #expect(AccountDesktop.rawHostId(" host:abc ") == "abc")
    #expect(AccountDesktop.rawHostId("abc") == "abc")
    let desktop = AccountDesktop(hostId: "abc", name: "Mac", osType: nil, osArch: nil, lastSeenAt: nil)
    #expect(desktop.cloudOrigin(relayBase: "https://relay.example.com/") == "https://relay.example.com/t/abc")
}
