import Foundation

@main struct DirectorySizeChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let total = try decoder.decode(DirectorySize.self, from: Data(#"{"size":5000000000,"storage_size":9000000000}"#.utf8))
        precondition(total.size == 5_000_000_000, "Display content bytes, not version-inclusive storage_size")
        let empty = try decoder.decode(DirectorySize.self, from: Data(#"{"size":0,"storage_size":42}"#.utf8))
        precondition(empty.size == 0)
        for invalid in [#"{}"#, #"null"#, #"{"size":null}"#, #"{"size":-1}"#,
                        #"{"size":"1024"}"#, #"{"size":1.5}"#, #"{"storage_size":1000}"#] {
            do {
                _ = try decoder.decode(DirectorySize.self, from: Data(invalid.utf8))
                preconditionFailure("Missing or malformed size must never become zero: \(invalid)")
            } catch is DecodingError { }
        }
        print("Folder size decoding: total, zero, missing, null, negative and malformed checks passed")
    }
}
