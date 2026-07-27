import Darwin
import Foundation
import LustreAgent

@main
struct LustreBrowserBridge {
    static func main() {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1] == BrowserCaptureConstants.extensionOrigin,
              let message = readNativeMessage(),
              message.count <= BrowserCaptureConstants.maximumMessageBytes
        else { exit(1) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { exit(1) }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = BrowserCaptureConstants.socketURL.path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(1) }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                _ = bytes.withUnsafeBufferPointer { source in strcpy(destination, source.baseAddress!) }
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { exit(1) }
        BrowserNativeFraming.write(message, to: descriptor)
        guard let response = BrowserNativeFraming.read(from: descriptor, maximumBytes: BrowserCaptureConstants.maximumMessageBytes) else { exit(1) }
        writeNativeMessage(response)
    }

    private static func readNativeMessage() -> Data? {
        let input = FileHandle.standardInput
        guard let header = try? input.read(upToCount: 4), header.count == 4 else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= BrowserCaptureConstants.maximumMessageBytes,
              let data = try? input.read(upToCount: Int(length)), data.count == Int(length)
        else { return nil }
        return data
    }

    private static func writeNativeMessage(_ data: Data) {
        var length = UInt32(data.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
        FileHandle.standardOutput.write(data)
    }
}
