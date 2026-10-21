import SwiftUI

/// Study groups: who's studying right now, and a leaderboard per group.
struct GroupsPane: View {
    @EnvironmentObject var c: SessionController
    private var sync: GroupSync { c.groupSync }
    @AppStorage("selectedGroup") private var selectedGroupID = ""
    @State private var showAdd = false

    private var selected: StudyGroup? { sync.groups.first { $0.groupID == selectedGroupID } ?? sync.groups.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if !sync.onlineEnabled {
                    OfflineHero()
                } else if sync.usingOwnDatabase && !sync.isConfigured {
                    NeedsDatabase()
                } else {
                    YouBar()
                    if sync.groups.isEmpty {
                        StartOrJoin { selectedGroupID = $0 }
                    } else {
                        if sync.groups.count > 1 { groupPicker }
                        if let group = selected { GroupDetail(group: group) }
                    }
                }
                if sync.onlineEnabled, let error = sync.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            if sync.isOnline {
                Button("Sync Now", systemImage: "arrow.clockwise") { Task { await sync.syncNow() } }
                    .disabled(sync.isSyncing || sync.groups.isEmpty)
                Button("New or Join Group", systemImage: "plus") { showAdd = true }
            }
        }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Add a Group").font(.title2.weight(.semibold))
                StartOrJoin { selectedGroupID = $0; showAdd = false }
                HStack { Spacer(); Button("Cancel") { showAdd = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(Theme.Space.xl)
            .frame(width: 560)
            .environmentObject(c)
        }
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(sync.groups) { group in
                    let isSelected = group.groupID == selected?.groupID
                    let live = (sync.members[group.groupID] ?? []).filter(\.isLive).count
                    Button { selectedGroupID = group.groupID } label: {
                        HStack(spacing: 6) {
                            Text(group.name).font(.callout.weight(.medium))
                            if live > 0 {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("\(live)").font(.caption.monospacedDigit())
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(isSelected ? Theme.accent.opacity(0.15) : Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.primary.opacity(0.08)))
                        .foregroundStyle(isSelected ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - You

/// Your nickname and what you share, in one line above the groups.
private struct YouBar: View {
    @EnvironmentObject var c: SessionController
    private var sync: GroupSync { c.groupSync }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            MemberAvatar(name: sync.nickname.isEmpty ? "?" : sync.nickname, size: 40, live: c.phase == .running)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(get: { sync.nickname }, set: { sync.nickname = $0 }), prompt: Text("Your nickname"))
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: 260)
                Text(sharingSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Toggle("Today's time", isOn: Binding(get: { sync.shareToday }, set: { sync.shareToday = $0 }))
                Toggle("Studying now", isOn: Binding(get: { sync.shareLive }, set: { sync.shareLive = $0 }))
                Toggle("Week and streak", isOn: Binding(get: { sync.shareWeek }, set: { sync.shareWeek = $0 }))
                Toggle("Subjects", isOn: Binding(get: { sync.shareSubjects }, set: { sync.shareSubjects = $0 }))
                Divider()
                Button("Privacy Settings…") { c.selectedPane = .privacy }
            } label: {
                Label("Sharing", systemImage: "lock.fill")
            }
            .fixedSize()
            .help("Choose what your groups can see. Everything is encrypted on this Mac first.")
        }
    }

    private var sharingSummary: String {
        let parts = [(sync.shareToday, "today"), (sync.shareLive, "live status"), (sync.shareWeek, "week & streak"), (sync.shareSubjects, "subjects")]
            .filter(\.0).map(\.1)
        let shared = parts.isEmpty ? "Sharing nothing" : "Sharing " + (ListFormatter.localizedString(byJoining: parts))
        let synced = sync.lastSync.map { " · synced \($0.formatted(.relative(presentation: .named)))" } ?? ""
        return shared + ", encrypted" + synced
    }
}

// MARK: - One group

private struct GroupDetail: View {
    @EnvironmentObject var c: SessionController
    let group: StudyGroup
    @State private var period = Period.today
    @State private var expanded: String?
    @State private var copied = false
    @State private var confirmLeave = false

    enum Period: String, CaseIterable { case today = "Today", week = "This Week" }

    private var members: [GroupMember] { c.groupSync.members[group.groupID] ?? [] }
    private var ranked: [GroupMember] { members.sorted { value($0) > value($1) } }

    /// Everyone in the group gets a different colour: their name's colour, or the next free one if it's taken.
    private var colors: [String: Color] {
        var taken = Set<Int>(), result: [String: Color] = [:]
        for m in members.sorted(by: { $0.id < $1.id }) {
            var index = avatarIndex(m.payload.name)
            for step in 0..<Subject.palette.count where !taken.contains((index + step) % Subject.palette.count) {
                index = (index + step) % Subject.palette.count; break
            }
            taken.insert(index)
            result[m.id] = Color(hex: Subject.palette[index])
        }
        return result
    }

    private func value(_ m: GroupMember) -> Double { period == .today ? todayNow(m, Date()) : (m.payload.weekSeconds ?? 0) }

    /// Your own status is always current; everyone else's comes from their last sync.
    private func isLive(_ m: GroupMember) -> Bool { m.isMe ? (c.phase == .running && !c.studyClockPaused) : m.isLive }

    /// Today's time, ticking for people studying right now (members sync once a minute, so it's carried forward).
    private func todayNow(_ m: GroupMember, _ now: Date) -> Double {
        if m.isMe { return c.todayTotal }
        guard m.isLive else { return m.today }
        return m.today + min(max(now.timeIntervalSince(m.payload.updated), 0), 180)
    }

    enum Tab: String, CaseIterable { case members = "Members", ranking = "Ranking" }
    @State private var tab = Tab.members

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            if members.isEmpty {
                invitePrompt
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        summary(context.date)
                        Picker("View", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        switch tab {
                        case .members: grid(context.date)
                        case .ranking: leaderboard
                        }
                    }
                }
            }
        }
        .confirmationDialog("Leave \(group.name)?", isPresented: $confirmLeave) {
            Button("Leave Group", role: .destructive) { c.groupSync.leave(group) }
        } message: {
            Text("Your row is deleted from the group. You can rejoin with the invite code.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.name).font(.largeTitle.weight(.semibold))
            Spacer()
            Button(copied ? "Copied" : "Invite", systemImage: copied ? "checkmark" : "person.badge.plus") { copyInvite() }
                .help(c.groupSync.usingOwnDatabase
                      ? "Copies the invite code. Friends also need your database's connection code from Settings → Privacy."
                      : "Copies the invite code. Anyone with it can see this group, so share it only with your group.")
            Menu {
                Button("Copy Invite Code") { copyInvite() }
                Divider()
                Button("Leave Group…", role: .destructive) { confirmLeave = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    /// Studying now, the group's total today, and today's leader.
    private func summary(_ now: Date) -> some View {
        let liveCount = members.filter(isLive).count
        let total = members.map { todayNow($0, now) }.reduce(0, +)
        let top = members.max { todayNow($0, now) < todayNow($1, now) }
        return HStack(spacing: Theme.Space.m) {
            SummaryTile(title: "Studying now", value: "\(liveCount)/\(members.count)", tint: liveCount > 0 ? .green : nil)
            SummaryTile(title: "Group today", value: formatHMS(total), tint: nil)
            SummaryTile(title: "Top today", value: top.map { $0.isMe ? "You" : $0.payload.name } ?? "—", tint: nil)
        }
    }

    /// Everyone as a tile: lit up while studying, faded while not. Studying first, then by time.
    private func grid(_ now: Date) -> some View {
        let order = members.sorted {
            let (a, b) = (isLive($0), isLive($1))
            return a != b ? a : todayNow($0, now) > todayNow($1, now)
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            ForEach(order) { m in tile(m, now: now) }
        }
    }

    private func tile(_ m: GroupMember, now: Date) -> some View {
        let live = isLive(m)
        let color = colors[m.id] ?? avatarColor(m.payload.name)
        let hidden = !m.isMe && m.payload.todaySeconds == nil
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return VStack(spacing: 6) {
            MemberAvatar(name: m.payload.name, size: 52, live: live, color: color)
                .saturation(live ? 1 : 0.25).opacity(live ? 1 : 0.6)
            Text(m.isMe ? "You" : m.payload.name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(hidden ? "—" : formatHMS(todayNow(m, now)))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(live ? Color.primary : .secondary)
                .contentTransition(.numericText())
            Text(live ? (m.payload.currentSubject ?? (m.isMe ? c.currentSubject?.name : nil) ?? "Studying") : restingStatus(m))
                .font(.caption.weight(live ? .semibold : .regular))
                .foregroundStyle(live ? color : .secondary)
                .lineLimit(1)
        }
        .padding(.vertical, Theme.Space.l).padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity)
        .background(live ? color.opacity(0.12) : Theme.card, in: shape)
        .overlay(shape.strokeBorder(live ? color.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: live ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if let streak = m.payload.streak, streak > 1 {
                Label("\(streak)", systemImage: "flame.fill").font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.accent).padding(8)
                    .help("\(streak)-day streak")
            }
        }
    }

    private func restingStatus(_ m: GroupMember) -> String {
        if m.isMe { return c.phase.isBreak ? "On a break" : "Not studying" }
        let ago = Date().timeIntervalSince(m.payload.updated)
        return ago < 120 ? "Resting" : "Seen \(formatDuration(ago)) ago"
    }

    private var invitePrompt: some View {
        Card {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "person.2.wave.2").font(.system(size: 36)).foregroundStyle(Theme.accent)
                Text(c.groupSync.isSyncing ? "Syncing…" : "No one here yet").font(.headline)
                Text("Send your friends the invite code. They paste it in Groups → + → Join a group.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(copied ? "Copied" : "Copy Invite Code") { copyInvite() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity).padding(.vertical, Theme.Space.l)
        }
    }

    private var leaderboard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    CardTitle("Ranking")
                    Spacer()
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                let top = max(ranked.map(value).max() ?? 0, 1)
                VStack(spacing: 2) {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, member in
                        row(rank: index + 1, member, top: top)
                    }
                }
            }
        }
    }

    private func row(rank: Int, _ m: GroupMember, top: Double) -> some View {
        let p = m.payload
        let seconds = value(m)
        let color = colors[m.id] ?? avatarColor(p.name)
        let hidden = m.isMe && period == .today ? false : (period == .today ? p.todaySeconds == nil : p.weekSeconds == nil)
        let hasSubjects = p.subjects?.isEmpty == false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.m) {
                RankBadge(rank: rank)
                MemberAvatar(name: p.name, size: 36, live: isLive(m), color: color)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                        if m.isMe { Chip(text: "You", color: Theme.accent) }
                        if let streak = p.streak, streak > 1 {
                            Label("\(streak)", systemImage: "flame.fill").font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                                .help("\(streak)-day streak")
                        }
                    }
                    ProgressBar(progress: hidden ? 0 : seconds / top, color: color, height: 5)
                    Text(status(m)).font(.caption).foregroundStyle(isLive(m) ? Color.green : .secondary).lineLimit(1)
                }
                Text(hidden ? "—" : (period == .today ? formatHMS(seconds) : formatHours(seconds)))
                    .font(.title3.monospacedDigit().weight(.medium))
                    .frame(minWidth: 84, alignment: .trailing)
            }
            if expanded == m.id, let subjects = p.subjects, !subjects.isEmpty {
                VStack(spacing: 4) {
                    ForEach(subjects.sorted { $0.value > $1.value }, id: \.key) { name, s in
                        HStack {
                            Text(name).font(.caption).frame(width: 110, alignment: .leading).lineLimit(1)
                            ProgressBar(progress: s / max(m.today, 1), color: color.opacity(0.7), height: 4)
                            Text(formatHours(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                .padding(.leading, 80).padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(m.isMe ? Theme.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if hasSubjects { expanded = expanded == m.id ? nil : m.id } }
        .help(hasSubjects ? "Click for subjects" : "")
    }

    private func status(_ m: GroupMember) -> String {
        if m.isMe && !isLive(m) { return restingStatus(m) }
        if isLive(m) { return "Studying" + (m.payload.currentSubject.map { " · \($0)" } ?? "") }
        let ago = Date().timeIntervalSince(m.payload.updated)
        return ago < 120 ? "Online" : "Seen \(formatDuration(ago)) ago"
    }

    private func copyInvite() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(group.inviteCode, forType: .string)
        copied = true
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let tint: Color?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(tint ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

private struct RankBadge: View {
    let rank: Int
    var body: some View {
        let medal: Color? = [1: Color(hex: "#E8B423"), 2: Color(hex: "#A7AFB8"), 3: Color(hex: "#C7804A")][rank]
        ZStack {
            if let medal { Circle().fill(medal.opacity(0.2)) }
            Text("\(rank)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(medal ?? .secondary)
        }
        .frame(width: 26, height: 26)
    }
}

/// A member's initial on a colour that stays the same for their name, with a green ring while they study.
struct MemberAvatar: View {
    let name: String
    var size: CGFloat = 32
    var live = false
    var color: Color?
    var body: some View {
        let gap = max(3, size * 0.08)
        Circle().fill((color ?? avatarColor(name)).gradient)
            .frame(width: size, height: size)
            .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .padding(gap)
            .overlay(Circle().strokeBorder(live ? Color.green : .clear, lineWidth: max(2, size * 0.06)))
    }
}

func avatarColor(_ name: String) -> Color { Color(hex: Subject.palette[avatarIndex(name)]) }

/// FNV-1a: stable across launches (Swift's hashValue isn't).
func avatarIndex(_ name: String) -> Int {
    let hash = name.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
    return Int(hash % UInt32(Subject.palette.count))
}

// MARK: - Empty states

/// Shown while online features are off: what groups are, and the opt-in.
private struct OfflineHero: View {
    @State private var confirm = false
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HStack(spacing: -12) {
                ForEach(Array(["A", "M", "J", "S"].enumerated()), id: \.offset) { i, letter in
                    Circle().fill(Color(hex: Subject.palette[i * 2 % Subject.palette.count]).gradient)
                        .frame(width: 56, height: 56)
                        .overlay(Text(letter).font(.title2.weight(.semibold)).foregroundStyle(.white))
                        .overlay(Circle().stroke(Theme.canvas, lineWidth: 3))
                }
            }
            .padding(.top, Theme.Space.xl)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Study with friends").font(.largeTitle.weight(.semibold))
                Text("See who's studying right now and compare today's time. Everything is end-to-end encrypted, so only your group can read it.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            Button("Turn On Online Features…") { confirm = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Label("Clocked is offline. Camera, microphone and detection never go online, even with this on.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
            OnlineDetails().frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .confirmGoingOnline(isPresented: $confirm)
    }
}

private struct NeedsDatabase: View {
    @EnvironmentObject var c: SessionController
    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(.secondary).padding(.top, Theme.Space.xl)
            Text("Connect your database").font(.title.weight(.semibold))
            Text("You chose to use your own Supabase database. Finish setting it up, or paste a friend's connection code, in Settings → Privacy.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button("Open Privacy Settings") { c.selectedPane = .privacy }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Create a group or join one with an invite code.
private struct StartOrJoin: View {
    @EnvironmentObject var c: SessionController
    let onDone: (String) -> Void
    @State private var name = ""
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.Space.l) { create; join }
            VStack(spacing: Theme.Space.l) { create; join }
        }
    }

    private var create: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Label("Start a group", systemImage: "person.3.fill").font(.headline).foregroundStyle(Theme.accent)
                Text("Then send the invite code to your friends.").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $name, prompt: Text("e.g. Year 12 Chem")).textFieldStyle(.roundedBorder)
                Button("Create Group") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    onDone(c.groupSync.create(name: trimmed.isEmpty ? "Study group" : trimmed).groupID)
                    name = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(minWidth: 240)
    }

    private var join: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Label("Join a group", systemImage: "person.badge.plus").font(.headline).foregroundStyle(Theme.accent)
                Text("Paste the invite code a friend sent you.").font(.callout).foregroundStyle(.secondary)
                TextField("", text: $code, prompt: Text("CLK1-…")).textFieldStyle(.roundedBorder).font(.body.monospaced())
                Button("Join Group") {
                    do {
                        try c.groupSync.join(code: code)
                        if let key = GroupCrypto.key(fromInvite: code) { onDone(GroupCrypto.groupID(forKey: key)) }
                        code = ""; error = nil
                    } catch let e { error = e.localizedDescription }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error { Text(error).font(.callout).foregroundStyle(Theme.warning) }
            }
        }
        .frame(minWidth: 240)
    }
}
