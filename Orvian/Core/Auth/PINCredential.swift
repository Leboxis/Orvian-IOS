import Foundation
import CommonCrypto
import CryptoKit
import Security

/// PBKDF2-HMAC-SHA256, sel aléatoire de 128 bits, 600 000 itérations.
/// Les appels de production sont exécutés hors du MainActor.
enum PINCredential {
    static let prefix = "pbkdf2-sha256$"
    private static let rounds: UInt32 = 600_000

    static func make(_ code: String) throws -> String {
        guard code.utf8.count == 4, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw CredentialError.invalidCode
        }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw CredentialError.derivationFailed
        }
        let key = try derive(code, salt: salt, rounds: rounds)
        return "\(prefix)\(rounds)$\(Data(salt).base64EncodedString())$\(Data(key).base64EncodedString())"
    }

    static func verify(_ code: String, record: String) throws -> Bool {
        if !record.hasPrefix(prefix) {
            let legacy = SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
            return equal(Array(legacy.utf8), Array(record.utf8))
        }
        let parts = record.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, let count = UInt32(parts[1]), count == rounds,
              let salt = Data(base64Encoded: String(parts[2])), salt.count == 16,
              let expected = Data(base64Encoded: String(parts[3])), expected.count == 32 else {
            throw CredentialError.derivationFailed
        }
        return equal(try derive(code, salt: Array(salt), rounds: count), Array(expected))
    }

    static func derive(_ code: String, salt: [UInt8], rounds: UInt32) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 32)
        let status = code.withCString { password in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, code.utf8.count,
                                    saltBytes.baseAddress, saltBytes.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, 32)
            }
        }
        guard status == kCCSuccess else { throw CredentialError.derivationFailed }
        return output
    }

    private static func equal(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    enum CredentialError: LocalizedError {
        case invalidCode, derivationFailed
        var errorDescription: String? { "Impossible de sécuriser ce code. Réessayez." }
    }
}

enum PINAttemptPolicy {
    static func delay(after failures: Int) -> TimeInterval {
        guard failures >= 5 else { return 0 }
        return min(3_600, 30 * pow(2, Double(min(failures - 5, 7))))
    }
}
