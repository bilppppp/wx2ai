import Cocoa

let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-chat-history.zip")
// Minimal valid empty zip header (22 bytes EOCD)
let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18))
try? emptyZip.write(to: tempZip)

let services = NSSharingService.sharingServices(forItems: [tempZip])
print("=== Available NSSharingServices for .zip (\(services.count)) ===")
for (idx, s) in services.enumerated() {
    print("  [\(idx + 1)] title='\(s.title)' menuItemTitle='\(s.menuItemTitle)'")
}
