// Decrypts a study group's rows with its invite code. Without the code the rows can't be read, not even by the
// database owner: the invite code is the group's encryption key (ChaCha20-Poly1305, 256-bit).
//
// Build: swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk Tools/decrypt-group.swift -o /tmp/decrypt-group
// Usage:
//   /tmp/decrypt-group CLK1-…                 fetch the group's rows from the database in supabase.env and decrypt them
//   /tmp/decrypt-group CLK1-… <payload> …     decrypt payloads copied from the Supabase table editor
import CryptoKit
import Foundation

func data(base64url s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let invite = args.first else { fail("Usage: decrypt-group CLK1-<key> [payload …]") }
let keyText = invite.hasPrefix("CLK1-") ? String(invite.dropFirst(5)) : invite
guard let keyData = data(base64url: keyText), keyData.count == 32 else { fail("That isn't a valid invite code.") }
let key = SymmetricKey(data: keyData)

// The row ID the database files the group under: a hash of the key, so the key itself never reaches it.
let groupID = SHA256.hash(data: Data(("clocked-group:" + keyText).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()

func decrypt(_ payload: String) -> String {
    guard let sealed = Data(base64Encoded: payload) else { return "(not base64)" }
    guard let box = try? ChaChaPoly.SealedBox(combined: sealed), let plain = try? ChaChaPoly.open(box, using: key) else {
        return "(doesn't decrypt with this invite code: another group's row, or tampered)"
    }
    guard let object = try? JSONSerialization.jsonObject(with: plain),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        return String(decoding: plain, as: UTF8.self)
    }
    return String(decoding: pretty, as: UTF8.self)
}

print("group_id: \(groupID)")
if args.count > 1 {
    for payload in args.dropFirst() { print(decrypt(payload)) }
    exit(0)
}

// Fetch mode: read SUPABASE_URL and the publishable key from supabase.env in the current folder.
guard let env = try? String(contentsOfFile: "supabase.env", encoding: .utf8) else {
    fail("No supabase.env here. Run from the project folder, or pass payloads to decrypt.")
}
var values: [String: String] = [:]
for line in env.split(separator: "\n") where !line.hasPrefix("#") {
    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'"))) }
    if parts.count == 2 { values[parts[0]] = parts[1] }
}
guard let base = values["SUPABASE_URL"], let apiKey = values["SUPABASE_PUBLISHABLE_KEY"] ?? values["SUPABASE_ANON_KEY"],
      let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/v1/clocked_members?group_id=eq.\(groupID)&select=member_id,payload,updated_at")
else { fail("supabase.env needs SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.") }

var request = URLRequest(url: url)
request.setValue(apiKey, forHTTPHeaderField: "apikey")
if apiKey.hasPrefix("eyJ") { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
request.setValue(groupID, forHTTPHeaderField: "x-group-id")  // the row-level security rule only shows this group's rows

let done = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: request) { body, response, error in
    defer { done.signal() }
    if let error { fail(error.localizedDescription) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let body else { fail("Database error \(status): \(String(decoding: body ?? Data(), as: UTF8.self))") }
    struct Row: Decodable { var member_id: String; var payload: String; var updated_at: String }
    guard let rows = try? JSONDecoder().decode([Row].self, from: body) else { fail("Unexpected reply from the database.") }
    print("\(rows.count) member\(rows.count == 1 ? "" : "s")")
    for row in rows { print("\n— member \(row.member_id), updated \(row.updated_at)\n\(decrypt(row.payload))") }
}.resume()
done.wait()
