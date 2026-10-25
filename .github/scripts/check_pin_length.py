"""Exercise production PIN format/store behavior; only crypto and storage are doubled.

Apple CommonCrypto/Security are unavailable on Windows. The existing macOS
check_ios_regressions.py still tests the actual PBKDF2 implementation and vector.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


STUBS = r'''
// TEST DOUBLES ONLY. Not cryptographic implementations.
let kSecRandomDefault = 0
let errSecSuccess: Int32 = 0
enum TestSalt { static var next: UInt8 = 0 }
func SecRandomCopyBytes(_ source: Int, _ count: Int, _ bytes: inout [UInt8]) -> Int32 {
    TestSalt.next &+= 1
    bytes = [UInt8](repeating: TestSalt.next, count: count)
    return errSecSuccess
}
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        precondition(String(data: data, encoding: .utf8) == "1234")
        let hex = "03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
@MainActor final class PINRecordStore {
    static var value: String?
    static var allowWrites = true
    func current() -> String? { Self.value }
    func save(_ value: String) -> Bool {
        guard Self.allowWrites else { return false }
        Self.value = value
        return true
    }
    func clear() { Self.value = nil }
}
'''


def main():
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("Swift compiler required for PIN length checks")
    credential = (ROOT / "Orvian/Core/Auth/PINCredential.swift").read_text(encoding="utf-8")
    for module in ["CommonCrypto", "CryptoKit", "Security"]:
        credential = credential.replace("import " + module, "")
    derive = block(credential, "    static func derive(")
    credential = credential.replace(derive, '''
    static func derive(_ code: String, salt: [UInt8], rounds: UInt32) throws -> [UInt8] {
        let input = Array(code.utf8) + salt
        return (0..<32).map { index in
            input[index % input.count] &+ UInt8(index)
        }
    }
''')
    store = (ROOT / "Orvian/Core/Auth/AppLockStore.swift").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="orvian-pin-length-") as temporary:
        directory = Path(temporary)
        production = directory / "PINProduction.swift"
        production.write_text(credential + STUBS + store, encoding="utf-8")
        for name in ["PINLengthChecks", "AppLockChecks"]:
            output = directory / (name + (".exe" if os.name == "nt" else ""))
            subprocess.run([compiler, "-parse-as-library", "-swift-version", "5",
                            str(production), str(ROOT / "Tests" / (name + ".swift")),
                            "-o", str(output)], check=True, timeout=120)
            subprocess.run([str(output)], check=True, timeout=30)


if __name__ == "__main__":
    main()
