// Study-group sync against an in-memory stand-in for Supabase that enforces the same row-level-security rules
// as SupabaseGroups.setupSQL. Checks encryption, invites, and that strangers can't read or tamper. Run with Tests/run.sh.
import CryptoKit
import Foundation
import ImageIO

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failures += 1 }
}

/// Mimics PostgREST + the policies: rows are visible only to requests whose x-group-id matches; inserts, updates
/// and deletes need x-member-secret whose SHA-256 equals the row's write_hash.
final class MockSupabase: SyncTransport {
    struct Row { var group: String; var member: String; var writeHash: String; var payload: String }
    var rows: [Row] = []
    var log: [SyncRequest] = []

    func send(_ r: SyncRequest) async throws -> SyncResponse {
        log.append(r)
        guard r.headers["apikey"] != nil else { return SyncResponse(status: 401, body: Data()) }
        let group = r.headers["x-group-id"] ?? ""
        let secretHash = GroupCrypto.sha256Hex(r.headers["x-member-secret"] ?? "")
        let query = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func eq(_ name: String) -> String? { query.first { $0.name == name }?.value.map { String($0.dropFirst(3)) } }
        switch r.method {
        case "POST":
            let body = try JSONDecoder().decode([String: String].self, from: r.body ?? Data())
            guard body["group_id"] == group, body["write_hash"] == secretHash else { return SyncResponse(status: 403, body: Data("rls".utf8)) }
            if let i = rows.firstIndex(where: { $0.group == body["group_id"] && $0.member == body["member_id"] }) {
                guard rows[i].writeHash == secretHash else { return SyncResponse(status: 403, body: Data("rls".utf8)) }
                rows[i].payload = body["payload"]!
            } else {
                rows.append(Row(group: body["group_id"]!, member: body["member_id"]!, writeHash: body["write_hash"]!, payload: body["payload"]!))
            }
            return SyncResponse(status: 201, body: Data())
        case "GET":
            let visible = rows.filter { $0.group == group && $0.group == eq("group_id") }
            let json = visible.map { ["member_id": $0.member, "payload": $0.payload] }
            return SyncResponse(status: 200, body: try JSONEncoder().encode(json))
        case "DELETE":
            rows.removeAll { $0.group == group && $0.group == eq("group_id") && $0.member == eq("member_id") && $0.writeHash == secretHash }
            return SyncResponse(status: 204, body: Data())
        default:
            return SyncResponse(status: 405, body: Data())
        }
    }
}

func payload(_ name: String, today: Double) -> MemberPayload {
    MemberPayload(name: name, groupName: "Year 12 Chem", day: StudyLog.key(Date()), todaySeconds: today, weekSeconds: today * 4,
                  streak: 3, studyingNow: true, currentSubject: "Chemistry", subjects: ["Chemistry": today], updated: Date())
}

@MainActor func run() async throws {
    // Crypto basics
    let key = GroupCrypto.newKey()
    let sealed = try GroupCrypto.seal(payload("Alice", today: 3600), key: key)
    check(try GroupCrypto.open(sealed, key: key) == payload("Alice", today: 3600).with(updated: try GroupCrypto.open(sealed, key: key).updated),
          "payload round-trips through encryption")
    check(!sealed.contains("Alice") && !sealed.contains("Chemistry"), "ciphertext contains no names or subjects")
    var tampered = Data(base64Encoded: sealed)!; tampered[tampered.count / 2] ^= 0x01
    check((try? GroupCrypto.open(tampered.base64EncodedString(), key: key)) == nil, "tampered data is rejected")
    check((try? GroupCrypto.open(sealed, key: GroupCrypto.newKey())) == nil, "a different key can't decrypt")
    check(GroupCrypto.groupID(forKey: key) == GroupCrypto.groupID(forKey: key) && !GroupCrypto.groupID(forKey: key).contains(key),
          "group ID is a stable hash and doesn't reveal the key")
    check(GroupCrypto.key(fromInvite: "CLK1-" + key) == key && GroupCrypto.key(fromInvite: "nonsense") == nil, "invite codes parse; junk is rejected")
    check(SyncPolicy.isAllowed(URL(string: "https://abc.supabase.co/rest/v1/x")!)
          && !SyncPolicy.isAllowed(URL(string: "http://abc.supabase.co")!)
          && !SyncPolicy.isAllowed(URL(string: "https://evil.example.com")!), "helper only allows https://*.supabase.co")
    let jwt = { (role: String) in "eyJhbGciOiJIUzI1NiJ9." + GroupCrypto.base64url(Data("{\"role\":\"\(role)\"}".utf8)) + ".sig" }
    check(GroupSync.isSecretKey("sb_secret_abc") && GroupSync.isSecretKey(jwt("service_role"))
          && !GroupSync.isSecretKey("sb_publishable_abc") && !GroupSync.isSecretKey(jwt("anon")),
          "secret keys are refused, publishable and anon keys are fine")

    // Alice creates a group, Bob joins with the invite code.
    let server = MockSupabase()
    let api = SupabaseGroups(baseURL: URL(string: "https://demo.supabase.co")!, anonKey: "anon", transport: server)
    let alice = StudyGroup(name: "Year 12 Chem", key: GroupCrypto.newKey(), memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret())
    let bob = StudyGroup(name: "Study group", key: GroupCrypto.key(fromInvite: alice.inviteCode)!, memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret())
    try await api.push(payload("Alice", today: 5400), to: alice)
    try await api.push(payload("Bob", today: 1800), to: bob)
    let seenByBob = try await api.fetch(bob)
    check(Set(seenByBob.map(\.payload.name)) == ["Alice", "Bob"], "Bob sees both members after joining")
    check(seenByBob.first { $0.payload.name == "Alice" }?.payload.todaySeconds == 5400, "Bob reads Alice's study time")
    check(seenByBob.first { $0.isMe }?.payload.name == "Bob", "Bob's own row is marked as his")
    check(server.rows.allSatisfy { !$0.payload.contains("Alice") && !$0.payload.contains("Bob") }, "server stores no readable names")
    check(server.log.allSatisfy { req in !(req.headers.values.contains(alice.key)) && !(req.url.absoluteString.contains(alice.key)) },
          "the group key never leaves the Mac")

    // Mallory: knows nothing / knows the group ID but not the key / tries to overwrite Alice.
    let strangerGroup = StudyGroup(name: "x", key: GroupCrypto.newKey(), memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret())
    let strangerSees = try await api.fetch(strangerGroup)
    check(strangerSees.isEmpty, "a stranger without the code sees nothing")
    let blob = server.rows.first!.payload
    check((try? GroupCrypto.open(blob, key: GroupCrypto.newKey())) == nil, "even with a stolen row, the data can't be read")
    var forged = alice; forged.memberSecret = GroupCrypto.newSecret() // right group and member ID, wrong write token
    var threw = false
    do { try await api.push(payload("Alice (hacked)", today: 0), to: forged) } catch { threw = true }
    let afterForgery = try await api.fetch(bob)
    check(threw && afterForgery.contains { $0.payload.name == "Alice" && $0.payload.todaySeconds == 5400 },
          "another member can't overwrite Alice's row")

    // Leaving deletes your row.
    try await api.leave(bob)
    let afterLeave = try await api.fetch(alice)
    check(afterLeave.map(\.payload.name) == ["Alice"], "leaving removes your row")

    // Profile photos: optional, encrypted with the rest, and small enough for the server's size limit.
    let picture = ProfilePhoto.square(testImage(width: 1200, height: 900, noise: false), size: ProfilePhoto.localSize, quality: 0.85)
    let pictureSize = picture.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    check(pictureSize?.width == 256 && pictureSize?.height == 256, "a landscape photo is cropped to a 256 px square")
    var withPhoto = payload("Alice", today: 3600)
    withPhoto.photo = picture.flatMap(ProfilePhoto.shared)
    let sealedPhoto = try GroupCrypto.seal(withPhoto, key: key)
    let openedPhoto = try GroupCrypto.open(sealedPhoto, key: key)
    check(withPhoto.photo != nil && openedPhoto.photo == withPhoto.photo, "a payload with a photo round-trips through encryption")

    // What a client from before photos sent: no photo field, slashes escaped.
    let oldJSON = #"{"name":"Old","groupName":"G","day":"2026-10-20","todaySeconds":60,"updated":"2026-10-20T10:00:00Z","subjects":{"Maths\/Stats":60}}"#
    let oldBox = try ChaChaPoly.seal(Data(oldJSON.utf8), using: SymmetricKey(data: GroupCrypto.data(base64url: key)!))
    let old = try? GroupCrypto.open(oldBox.combined.base64EncodedString(), key: key)
    check(old?.name == "Old" && old?.photo == nil && old?.subjects?["Maths/Stats"] == 60, "an older payload without a photo still decodes")

    // Worst case: the longest realistic nickname, 8 subjects, and a photo of pure noise (the hardest thing for JPEG).
    var big = payload(String(repeating: "Alexandra-Catherine ", count: 3), today: 20_000)
    big.groupName = "Year 12 Chemistry and Physics Study Group"
    big.currentSubject = "Advanced Mathematics Extension 2"
    big.subjects = Dictionary(uniqueKeysWithValues: ["Advanced Mathematics Extension 2", "Chemistry (HSC)", "Physics Module 7",
        "English Advanced", "Modern History Research", "Economics Case Studies", "Software Engineering", "Biology Practicals"]
        .enumerated().map { ($1, Double(1000 + $0 * 977) + 0.123456789) })
    let noAvatar = try GroupCrypto.seal(big, key: key).count
    // The noise is made at the size it's sent at, so downscaling can't smooth it out.
    for (label, side, noise) in [("photo", 3024, false), ("noise photo", ProfilePhoto.sharedSize, true)] {
        big.photo = ProfilePhoto.square(testImage(width: side, height: side * 4 / 3, noise: noise), size: ProfilePhoto.localSize, quality: 0.85)
            .flatMap(ProfilePhoto.shared)
        let size = try GroupCrypto.seal(big, key: key).count
        print("     sizes: no photo \(noAvatar), with \(label) \(size) characters (photo \(big.photo?.count ?? 0)); limit 16384")
        check(big.photo != nil && size < 10_000, "a full payload with a \(label) stays well under the 16,384-character limit")
    }
    check(ProfilePhoto.square(Data("not an image".utf8), size: 64, quality: 0.7) == nil, "non-images are refused")

    // The setup SQL defines the table, the policies and grants used above.
    let sql = SupabaseGroups.setupSQL
    check(["enable row level security", "for select", "for insert", "for update", "for delete", "x-group-id", "x-member-secret", "grant select"]
            .allSatisfy(sql.contains), "setup SQL has row-level security for every operation")
}

extension MemberPayload { func with(updated: Date) -> MemberPayload { var p = self; p.updated = updated; return p } }

/// A PNG test picture: a smooth gradient with some shapes, or random noise.
func testImage(width: Int, height: Int, noise: Bool) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if noise {
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(context.bytesPerRow * height) { pixels[i] = i % 4 == 3 ? 255 : UInt8.random(in: 0...255) }
    } else {
        for y in stride(from: 0, to: height, by: 8) {
            context.setFillColor(CGColor(red: Double(y) / Double(height), green: 0.5, blue: 1 - Double(y) / Double(height), alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 8))
        }
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.8, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: width / 3, height: height / 2))
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

Task { @MainActor in
    do { try await run() } catch { check(false, "unexpected error: \(error)") }
    print(failures == 0 ? "All group sync tests passed." : "\(failures) group sync test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
