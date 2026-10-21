import CryptoKit
import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

/// A study group you belong to. The invite code *is* the group's secret key; everything shared is encrypted with it.
struct StudyGroup: Codable, Identifiable, Equatable {
    var id: String { groupID }
    var name: String
    /// 32-byte symmetric key (base64url). Never sent anywhere except inside the invite code you share.
    var key: String
    /// Random ID for you in this group (the server sees it, it means nothing).
    var memberID: String
    /// Proves it's you when updating or deleting your row (the server only stores its hash).
    var memberSecret: String

    var groupID: String { GroupCrypto.groupID(forKey: key) }
    var inviteCode: String { "CLK1-" + key }
}

/// What you share with a group, decrypted. Each part can be switched off.
struct MemberPayload: Codable, Equatable {
    var name: String
    var groupName: String
    var day: String                    // yyyy-MM-dd, so stale "today" values aren't shown as today
    var todaySeconds: Double?
    var weekSeconds: Double?
    var streak: Int?
    var studyingNow: Bool?
    var currentSubject: String?
    var subjects: [String: Double]?    // per-subject seconds today
    var updated: Date
    var photo: String?                 // base64 JPEG, about 64 px (see ProfilePhoto); optional so older payloads still decode
}

struct GroupMember: Identifiable, Equatable {
    var id: String
    var payload: MemberPayload
    var isMe: Bool

    /// "Studying now" only counts if the update is recent.
    var isLive: Bool { payload.studyingNow == true && Date().timeIntervalSince(payload.updated) < 180 }
    var today: Double { payload.day == StudyLog.key(Date()) ? (payload.todaySeconds ?? 0) : 0 }
}

// MARK: - Crypto

enum GroupCrypto {
    static func newKey() -> String { base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
    static func newSecret() -> String { base64url(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }

    /// The public ID of a group: a hash of its key, so the key itself never reaches the server.
    static func groupID(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(("clocked-group:" + key).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func seal(_ payload: MemberPayload, key: String) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .withoutEscapingSlashes   // keeps a base64 photo from growing "/" into "\/"
        let box = try ChaChaPoly.seal(try encoder.encode(payload), using: try symmetricKey(key))
        return box.combined.base64EncodedString()
    }

    static func open(_ blob: String, key: String) throws -> MemberPayload {
        guard let data = Data(base64Encoded: blob) else { throw GroupError.corrupt }
        let plain = try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: data), using: try symmetricKey(key))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MemberPayload.self, from: plain)
    }

    /// Accepts "CLK1-<key>" or the bare key.
    static func key(fromInvite code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.hasPrefix("CLK1-") ? String(trimmed.dropFirst(5)) : trimmed
        guard let data = data(base64url: key), data.count == 32 else { return nil }
        return key
    }

    private static func symmetricKey(_ key: String) throws -> SymmetricKey {
        guard let data = data(base64url: key), data.count == 32 else { throw GroupError.badKey }
        return SymmetricKey(data: data)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

enum GroupError: LocalizedError {
    case badKey, badConnectionCode, corrupt, notConfigured, http(Int, String), transport(String)
    var errorDescription: String? {
        switch self {
        case .badKey: return "That invite code isn't valid."
        case .corrupt: return "Received data that couldn't be read."
        case .badConnectionCode: return "That connection code isn't valid. It starts with CLKDB1-."
        case .notConfigured: return "Finish setting up your database in Settings → Privacy."
        case .http(let code, let body): return "Server error \(code)\(body.isEmpty ? "" : ": \(body.prefix(140))")"
        case .transport(let message): return message
        }
    }
}

// MARK: - Profile photo

/// Your profile picture, cropped to a centred square and kept small. A 256 px copy stays on this Mac; groups get a
/// 64 px copy only if you choose to share it, inside the encrypted payload like everything else.
enum ProfilePhoto {
    static let localSize = 256
    static let sharedSize = 64
    /// Base64 characters a shared photo may use. The server refuses payloads over 16,384 characters (see setupSQL);
    /// with this cap a full payload stays under about 8,000.
    static let sharedBudget = 5000

    /// A square JPEG of the middle of an image file or image data. Nil if it isn't an image.
    static func square(_ source: CGImageSource, size: Int, quality: Double) -> Data? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        // Decode only as many pixels as needed: the short side ends up at `size` (or the original, if smaller).
        let longSide = Double(size) * Double(max(w, h)) / Double(min(w, h))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,   // respects camera rotation
                                        kCGImageSourceThumbnailMaxPixelSize: Int(longSide.rounded(.up))]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = min(image.width, image.height)
        guard let cropped = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))   // transparent images go on white, not black
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func square(_ data: Data, size: Int, quality: Double) -> Data? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { square($0, size: size, quality: quality) }
    }

    static func square(_ url: URL, size: Int, quality: Double) -> Data? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { square($0, size: size, quality: quality) }
    }

    /// The copy groups see: 64 px, or smaller and rougher if a busy photo would go over the budget.
    static func shared(from jpeg: Data) -> String? {
        for (size, quality) in [(sharedSize, 0.7), (56, 0.6), (48, 0.5), (40, 0.4)] {
            if let small = square(jpeg, size: size, quality: quality), (small.count + 2) / 3 * 4 <= sharedBudget {
                return small.base64EncodedString()
            }
        }
        return nil
    }
}

// MARK: - Supabase client

/// Sends requests somewhere: through the network-only XPC helper in the app, or directly in tests.
protocol SyncTransport {
    func send(_ request: SyncRequest) async throws -> SyncResponse
}

/// Talks to the ClockedSync helper, the only Clocked process allowed on the network.
final class XPCSyncTransport: SyncTransport {
    private lazy var connection: NSXPCConnection = {
        let c = NSXPCConnection(serviceName: "com.davidxie.clocked.sync")
        c.remoteObjectInterface = NSXPCInterface(with: ClockedSyncXPC.self)
        c.resume()
        return c
    }()

    func send(_ request: SyncRequest) async throws -> SyncResponse {
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: GroupError.transport($0.localizedDescription)) }
            guard let service = proxy as? ClockedSyncXPC else {
                continuation.resume(throwing: GroupError.transport("Sync helper unavailable")); return
            }
            service.perform(data) { reply, error in
                if let error { continuation.resume(throwing: GroupError.transport(error)); return }
                guard let reply, let response = try? JSONDecoder().decode(SyncResponse.self, from: reply) else {
                    continuation.resume(throwing: GroupError.transport("No response")); return
                }
                continuation.resume(returning: response)
            }
        }
    }
}

/// The three calls Clocked makes. The server only ever sees: a group ID (hash of the key), a random member ID,
/// the hash of your write token, a timestamp, and an encrypted blob.
struct SupabaseGroups {
    var baseURL: URL
    var anonKey: String
    var transport: SyncTransport

    static let table = "clocked_members"

    private func headers(_ group: StudyGroup, secret: Bool) -> [String: String] {
        var h = ["apikey": anonKey, "Content-Type": "application/json",
                 "x-group-id": group.groupID]
        // Publishable keys (sb_publishable_…) go in `apikey` only; legacy anon keys are JWTs and also go as Bearer.
        if anonKey.hasPrefix("eyJ") { h["Authorization"] = "Bearer \(anonKey)" }
        if secret { h["x-member-secret"] = group.memberSecret }
        return h
    }

    private func url(_ query: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/rest/v1/\(Self.table)" + query)!
    }

    func push(_ payload: MemberPayload, to group: StudyGroup) async throws {
        let row: [String: String] = [
            "group_id": group.groupID, "member_id": group.memberID,
            "write_hash": GroupCrypto.sha256Hex(group.memberSecret),
            "payload": try GroupCrypto.seal(payload, key: group.key),
            "updated_at": ISO8601DateFormatter().string(from: payload.updated),
        ]
        var h = headers(group, secret: true)
        h["Prefer"] = "resolution=merge-duplicates,return=minimal"
        let response = try await transport.send(SyncRequest(method: "POST", url: url("?on_conflict=group_id,member_id"),
                                                            headers: h, body: try JSONEncoder().encode(row)))
        try check(response)
    }

    func fetch(_ group: StudyGroup) async throws -> [GroupMember] {
        let response = try await transport.send(SyncRequest(method: "GET", url: url("?group_id=eq.\(group.groupID)&select=member_id,payload"),
                                                            headers: headers(group, secret: false), body: nil))
        try check(response)
        struct Row: Decodable { var member_id: String; var payload: String }
        let rows = try JSONDecoder().decode([Row].self, from: response.body)
        return rows.compactMap { row in
            // Rows that don't decrypt with the group key are ignored (tampering or a different group).
            guard let payload = try? GroupCrypto.open(row.payload, key: group.key) else { return nil }
            return GroupMember(id: row.member_id, payload: payload, isMe: row.member_id == group.memberID)
        }
    }

    func leave(_ group: StudyGroup) async throws {
        let response = try await transport.send(SyncRequest(method: "DELETE", url: url("?group_id=eq.\(group.groupID)&member_id=eq.\(group.memberID)"),
                                                            headers: headers(group, secret: true), body: nil))
        try check(response)
    }

    private func check(_ r: SyncResponse) throws {
        guard (200..<300).contains(r.status) else { throw GroupError.http(r.status, String(data: r.body, encoding: .utf8) ?? "") }
    }

    /// Run once in the Supabase SQL editor. Row-level security means a client can only see rows of a group whose
    /// ID it presents, and only change its own row (proved with the write token).
    /// Safe to run again: it only adds what's missing and replaces the rules.
    static let setupSQL = """
    create extension if not exists pgcrypto with schema extensions;

    create table if not exists public.clocked_members (
      group_id   text not null,
      member_id  text not null,
      write_hash text not null,
      payload    text not null,
      updated_at timestamptz not null default now(),
      primary key (group_id, member_id)
    );
    alter table public.clocked_members enable row level security;

    -- Limits so nobody can use your free project as storage.
    alter table public.clocked_members drop constraint if exists clocked_sizes;
    alter table public.clocked_members add constraint clocked_sizes check (
      group_id ~ '^[0-9a-f]{32}$' and length(member_id) between 8 and 64
      and write_hash ~ '^[0-9a-f]{64}$' and length(payload) <= 16384);

    create or replace function public.clocked_header(name text) returns text
      language sql stable set search_path = '' as $$
        select coalesce(current_setting('request.headers', true)::json ->> name, '')
      $$;

    create or replace function public.clocked_secret_ok(hash text) returns boolean
      language sql stable set search_path = '' as $$
        select hash = encode(extensions.digest(public.clocked_header('x-member-secret'), 'sha256'), 'hex')
      $$;

    -- At most 100 people per group.
    create or replace function public.clocked_group_cap() returns trigger
      language plpgsql security definer set search_path = '' as $$
      begin
        if (select count(*) from public.clocked_members where group_id = new.group_id) >= 100 then
          raise exception 'group is full';
        end if;
        return new;
      end $$;
    drop trigger if exists clocked_group_cap on public.clocked_members;
    create trigger clocked_group_cap before insert on public.clocked_members
      for each row execute function public.clocked_group_cap();

    -- Read: only rows of the group whose ID you send (which needs the invite code).
    -- Write: only your own row, proven by the secret only your Mac has.
    drop policy if exists clocked_read on public.clocked_members;
    drop policy if exists clocked_insert on public.clocked_members;
    drop policy if exists clocked_update on public.clocked_members;
    drop policy if exists clocked_delete on public.clocked_members;
    create policy clocked_read on public.clocked_members for select to anon
      using (group_id = public.clocked_header('x-group-id'));
    create policy clocked_insert on public.clocked_members for insert to anon
      with check (group_id = public.clocked_header('x-group-id') and public.clocked_secret_ok(write_hash));
    create policy clocked_update on public.clocked_members for update to anon
      using (group_id = public.clocked_header('x-group-id') and public.clocked_secret_ok(write_hash))
      with check (group_id = public.clocked_header('x-group-id') and public.clocked_secret_ok(write_hash));
    create policy clocked_delete on public.clocked_members for delete to anon
      using (group_id = public.clocked_header('x-group-id') and public.clocked_secret_ok(write_hash));

    revoke all on public.clocked_members from anon, authenticated;
    grant select, insert, update, delete on public.clocked_members to anon;
    revoke execute on function public.clocked_group_cap() from public, anon, authenticated;
    """
}

// MARK: - Store and sync loop

/// Your groups, nickname and sharing choices (in the app's private container), and the latest member lists.
@MainActor
final class GroupSync: ObservableObject {
    @Published private(set) var groups: [StudyGroup] = []
    @Published private(set) var members: [String: [GroupMember]] = [:]
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    @Published var nickname: String { didSet { save() } }
    @Published var shareToday: Bool { didSet { save() } }
    @Published var shareLive: Bool { didSet { save() } }
    @Published var shareWeek: Bool { didSet { save() } }
    @Published var shareSubjects: Bool { didSet { save() } }
    @Published var sharePhoto: Bool { didSet { save() } }
    /// Your profile picture (a 256 px JPEG), kept on this Mac. Groups only get a small copy, and only with `sharePhoto` on.
    @Published private(set) var photo: Data?
    @Published var supabaseURL: String { didSet { save() } }
    @Published var supabaseKey: String { didSet { save() } }
    /// Use your own Supabase project instead of Clocked's database (Settings → Privacy). Everyone in a group must use
    /// the same database, so friends paste the same connection code.
    @Published var useOwnDatabase: Bool {
        didSet { save(); members = [:]; lastError = nil; startSyncing() }
    }
    /// Master switch for everything online. Off by default: while it's off, Clocked never contacts any server
    /// (the network helper isn't even started).
    @Published var onlineEnabled: Bool {
        didSet {
            save()
            if onlineEnabled { startSyncing() } else { stopSyncing() }
        }
    }

    private let file = Storage.file("groups.json")
    private let photoFile = Storage.file("photo.jpg")
    /// The small base64 copy that goes into payloads, made once when the photo changes.
    private var sharedPhoto: String?
    private let transport: SyncTransport
    private var timer: Timer?
    /// Supplies what to share (set by the session controller).
    var snapshot: (() -> MemberPayload)?

    private struct Saved: Codable {
        var groups: [StudyGroup] = []
        var nickname = ""
        var shareToday = true, shareLive = true, shareWeek = true, shareSubjects = true
        var supabaseURL = "", supabaseKey = ""
        var onlineEnabled: Bool?
        var useOwnDatabase: Bool?
        var sharePhoto: Bool?
    }

    init(transport: SyncTransport = XPCSyncTransport()) {
        self.transport = transport
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        groups = saved.groups
        nickname = saved.nickname
        shareToday = saved.shareToday; shareLive = saved.shareLive; shareWeek = saved.shareWeek; shareSubjects = saved.shareSubjects
        sharePhoto = saved.sharePhoto ?? false
        let savedPhoto = try? Data(contentsOf: photoFile)
        photo = savedPhoto
        sharedPhoto = savedPhoto.flatMap(ProfilePhoto.shared)
        supabaseURL = saved.supabaseURL; supabaseKey = saved.supabaseKey
        // Earlier versions had no switch; a backend you had already connected counts as having opted in.
        onlineEnabled = saved.onlineEnabled ?? !saved.supabaseURL.isEmpty
        useOwnDatabase = saved.useOwnDatabase ?? !saved.supabaseURL.isEmpty
    }

    /// The project built in from supabase.env at build time (see build.sh), if any.
    static let builtIn: (url: String, key: String)? = {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "ClockedSupabaseURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "ClockedSupabaseKey") as? String,
              !url.isEmpty, !key.isEmpty else { return nil }
        return (url, key)
    }()

    /// Your own database if you chose one (or this build has none built in); otherwise Clocked's.
    var usingOwnDatabase: Bool { useOwnDatabase || Self.builtIn == nil }
    private var effectiveURL: String { usingOwnDatabase ? supabaseURL.trimmingCharacters(in: .whitespaces) : Self.builtIn!.url }
    private var effectiveKey: String { usingOwnDatabase ? supabaseKey.trimmingCharacters(in: .whitespaces) : Self.builtIn!.key }

    /// Where group data goes, in words.
    var databaseDescription: String {
        usingOwnDatabase
            ? "your own Supabase database" + (URL(string: effectiveURL)?.host.map { " (\($0))" } ?? "")
            : "Clocked's study-groups database (hosted by Supabase)"
    }

    /// A secret key bypasses all the database's rules, so it's never used.
    static func isSecretKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") { return true }
        let parts = key.split(separator: ".")
        guard key.hasPrefix("eyJ"), parts.count == 3 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }?.contains("service_role") ?? false
    }
    var hasSecretKey: Bool { usingOwnDatabase && Self.isSecretKey(effectiveKey) }

    /// Your database's address and publishable key in one code, for friends to paste in Settings → Privacy.
    var connectionCode: String? {
        guard usingOwnDatabase, isConfigured,
              let json = try? JSONEncoder().encode(["url": effectiveURL, "key": effectiveKey]) else { return nil }
        return "CLKDB1-" + GroupCrypto.base64url(json)
    }

    func useConnectionCode(_ code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("CLKDB1-"), let data = GroupCrypto.data(base64url: String(trimmed.dropFirst(7))),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              let url = dict["url"], let key = dict["key"], let parsed = URL(string: url), SyncPolicy.isAllowed(parsed),
              !Self.isSecretKey(key) else { throw GroupError.badConnectionCode }
        supabaseURL = url
        supabaseKey = key
        useOwnDatabase = true
    }

    /// A backend URL and key are available (whether or not online features are on).
    var isConfigured: Bool { backend != nil }
    /// Actually allowed to go online right now.
    var isOnline: Bool { onlineEnabled && isConfigured }

    /// The only way anything reaches the network: nil whenever online features are off.
    private var client: SupabaseGroups? { onlineEnabled ? backend : nil }

    private var backend: SupabaseGroups? {
        guard let url = URL(string: effectiveURL), SyncPolicy.isAllowed(url), !effectiveKey.isEmpty,
              !Self.isSecretKey(effectiveKey) else { return nil }
        return SupabaseGroups(baseURL: url, anonKey: effectiveKey, transport: transport)
    }

    /// Syncs every minute while you're in at least one group.
    func startSyncing() {
        timer?.invalidate()
        guard isOnline, !groups.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncNow() }
        }
        Task { await syncNow() }
    }

    func syncNow() async {
        guard let client, let snapshot, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            for group in groups {
                var payload = snapshot()
                payload.groupName = group.name
                payload.name = nickname.trimmingCharacters(in: .whitespaces).isEmpty ? "Anonymous" : nickname
                // Only what you've chosen to share leaves the Mac (encrypted).
                if !shareToday { payload.todaySeconds = nil }
                if !shareLive { payload.studyingNow = nil; payload.currentSubject = nil }
                if !shareWeek { payload.weekSeconds = nil; payload.streak = nil }
                if !shareSubjects { payload.subjects = nil }
                payload.photo = sharePhoto ? sharedPhoto : nil
                try await client.push(payload, to: group)
                members[group.groupID] = try await client.fetch(group)
            }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopSyncing() {
        timer?.invalidate()
        timer = nil
        members = [:]
        lastSync = nil
    }

    func testConnection() async -> String? {
        guard let client else { return onlineEnabled ? GroupError.notConfigured.localizedDescription : "Online features are off." }
        let probe = StudyGroup(name: "probe", key: GroupCrypto.newKey(), memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret())
        do { _ = try await client.fetch(probe); return nil } catch { return error.localizedDescription }
    }

    /// Saves a new profile picture (already cropped and shrunk by ProfilePhoto). Groups see it on the next sync if shared.
    func setPhoto(_ jpeg: Data) {
        try? FileManager.default.createDirectory(at: photoFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jpeg.write(to: photoFile, options: [.atomic, .completeFileProtection])
        photo = jpeg
        sharedPhoto = ProfilePhoto.shared(from: jpeg)
    }

    func removePhoto() {
        try? FileManager.default.removeItem(at: photoFile)
        photo = nil
        sharedPhoto = nil
    }

    @discardableResult
    func create(name: String) -> StudyGroup {
        let group = StudyGroup(name: name, key: GroupCrypto.newKey(), memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret())
        groups.append(group)
        save()
        startSyncing()
        return group
    }

    func join(code: String) throws {
        guard let key = GroupCrypto.key(fromInvite: code) else { throw GroupError.badKey }
        guard !groups.contains(where: { $0.key == key }) else { return }
        groups.append(StudyGroup(name: "Study group", key: key, memberID: UUID().uuidString, memberSecret: GroupCrypto.newSecret()))
        save()
        startSyncing()
        // The real name arrives with the other members' payloads.
        Task { await syncNow(); adoptGroupNames() }
    }

    func leave(_ group: StudyGroup) {
        groups.removeAll { $0.groupID == group.groupID }
        members[group.groupID] = nil
        save()
        if let client { Task { try? await client.leave(group) } }
        if groups.isEmpty { timer?.invalidate() }
    }

    private func adoptGroupNames() {
        for (i, g) in groups.enumerated() where g.name == "Study group" {
            if let name = members[g.groupID]?.first(where: { !$0.isMe })?.payload.groupName, !name.isEmpty {
                groups[i].name = name
            }
        }
        save()
    }

    /// Delete everything about groups from this Mac (and, if online, your rows on the server).
    func removeEverything() async {
        if let client { for group in groups { try? await client.leave(group) } }
        stopSyncing()
        groups = []
        nickname = ""
        removePhoto()
        sharePhoto = false
        supabaseURL = ""; supabaseKey = ""
        useOwnDatabase = false
        onlineEnabled = false
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        let saved = Saved(groups: groups, nickname: nickname, shareToday: shareToday, shareLive: shareLive, shareWeek: shareWeek,
                          shareSubjects: shareSubjects, supabaseURL: supabaseURL, supabaseKey: supabaseKey, onlineEnabled: onlineEnabled,
                          useOwnDatabase: useOwnDatabase, sharePhoto: sharePhoto)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: [.atomic, .completeFileProtection]) }
    }
}
