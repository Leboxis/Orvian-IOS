import Foundation

@main
struct TextFileContentChecks {
    static func main() throws {
        let text = "Bonjour, été 👋\nDeuxième ligne\t!"
        for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]),
                                (.utf16BigEndian, [UInt8(0xFE), 0xFF])] {
            let data = Data(bom) + text.data(using: encoding)!
            let decoded = try TextFileContent.decode(data)
            precondition(decoded == text, "UTF-16 text must not be rejected as binary")
        }
        for (data, expected) in [(Data(), ""), (Data("été\n".utf8), "été\n"),
                                 (Data([0xE9, 0x74, 0xE9]), "été")] {
            let decoded = try TextFileContent.decode(data)
            precondition(decoded == expected)
        }
        let nullText = Data([0xFF, 0xFE]) + "Bonjour\0".data(using: .utf16LittleEndian)!
        for data in [Data([0x50, 0x4B, 0x03, 0x04, 0x00]), nullText] {
            do {
                _ = try TextFileContent.decode(data)
                preconditionFailure("Binary content must still be rejected")
            } catch TextFileContent.DecodeError.binaryContent {}
        }
        print("Text encoding and binary detection checks passed")
    }
}
