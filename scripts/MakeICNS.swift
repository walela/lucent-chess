import Foundation

@main
struct MakeICNS {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "MakeICNS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: MakeICNS iconset output.icns"])
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let entries = [
            ("icp4", "icon_16x16.png"),
            ("icp5", "icon_32x32.png"),
            ("icp6", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic08", "icon_256x256.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png")
        ]
        var chunks = Data()
        for (type, name) in entries {
            let png = try Data(contentsOf: folder.appendingPathComponent(name))
            chunks.append(type.data(using: .ascii)!)
            appendUInt32(UInt32(png.count + 8), to: &chunks)
            chunks.append(png)
        }
        var result = Data("icns".utf8)
        appendUInt32(UInt32(chunks.count + 8), to: &result)
        result.append(chunks)
        try result.write(to: output, options: .atomic)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
