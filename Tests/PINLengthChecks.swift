import Foundation

@main struct PINLengthChecks {
    static func main() throws {
        precondition(PINCredential.newCodeLength == 6)
        precondition(PINCredential.requiredLength(for: nil) == 6)
        for code in ["000000", "012345", "999999"] {
            let record = try PINCredential.make(code)
            precondition(record.split(separator: "$").count == 5 && record.hasSuffix("$6"))
            precondition(PINCredential.requiredLength(for: record) == 6)
            let accepted = try PINCredential.verify(code, record: record)
            let shortened = try PINCredential.verify(String(code.prefix(4)), record: record)
            let nonASCII = try PINCredential.verify("１２３４５６", record: record)
            precondition(accepted && !shortened && !nonASCII)
        }
        for code in ["", "1234", "12345", "1234567", "12345a", "１２３４５６", "123 45"] {
            do {
                _ = try PINCredential.make(code)
                preconditionFailure("Only six ASCII digits may create a new code")
            } catch PINCredential.CredentialError.invalidCode {}
        }
        let upgraded = try PINCredential.upgradeLegacy("0123")
        let existing = upgraded.split(separator: "$").dropLast().joined(separator: "$")
        for record in [existing, upgraded] {
            precondition(PINCredential.requiredLength(for: record) == 4)
            let accepted = try PINCredential.verify("0123", record: record)
            let padded = try PINCredential.verify("012300", record: record)
            precondition(accepted && !padded)
        }
        for suffix in ["$5", "$06", "$", "$6$extra"] {
            do {
                _ = try PINCredential.verify("012345", record: existing + suffix)
                preconditionFailure("Malformed length metadata must fail closed")
            } catch PINCredential.CredentialError.derivationFailed {}
        }
        print("PIN length and old/new record compatibility checks passed")
    }
}
