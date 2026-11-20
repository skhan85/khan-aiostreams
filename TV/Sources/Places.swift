import SwiftUI

// Calendar and Activity, from the web app's pages/calendar.tsx and pages/history.tsx: what
// airs in the coming days, and what was watched, each grouped by day.

/// "Today", "Tomorrow", "Yesterday", or the weekday and date.
private func dayName(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return L("Today") }
    if calendar.isDateInTomorrow(date) { return L("Tomorrow") }
    if calendar.isDateInYesterday(date) { return L("Yesterday") }
    return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.locale))
}

private let isoParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoPlain = ISO8601DateFormatter()

/// A Jellyfin date, which can carry more fractional digits than the parser takes.
func parseDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    // Jellyfin gives seven fractional digits, more than the parser takes.
    if let date = isoParser.date(from: text) ?? isoPlain.date(from: text) { return date }
    let trimmed = text.replacingOccurrences(of: #"\.(\d{3})\d*"#, with: ".$1", options: .regularExpression)
    return isoParser.date(from: trimmed)
}

/// A day's heading and its row of stills.
private struct DayRow: View {
    let title: String
    let detail: String?
    let items: [Item]
    let play: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.px(10)) {
                Text(title).font(Theme.font(Theme.lg, .semibold))
                if let detail { Text(detail).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400) }
            }
            .pagePadding()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(items) { item in
                        WideCard(item: item) { play(item) }
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
        }
        .focusSection()
    }
}

// MARK: - Calendar

/// The local day something airs; a date with no time of day (midnight UTC) keeps its own day,
/// as the web app's `airDay` has it.
private func airDay(_ text: String?) -> (day: Date, timed: Date?)? {
    guard let text, let date = parseDate(text) else { return nil }
    let dateOnly = !text.contains("T") || text.range(of: #"T00:00:00(\.0+)?Z$"#, options: .regularExpression) != nil
    if dateOnly {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: date)
        return (Calendar.current.date(from: parts) ?? date, nil)
    }
    return (Calendar.current.startOfDay(for: date), date)
}

/// A month of what airs from your shows and watchlist, as the web app's calendar on a TV: the
/// month's weeks in a card, each day with its first title's art, up to two titles and a count of
/// the rest; a day opens its whole list.
struct CalendarView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.openRoute) private var openRoute
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var byDay: [Date: [Item]] = [:]
    @State private var loading = true
    @State private var failed = false
    @State private var opened: CalendarDay?

    private static let shownPerDay = 2

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = AppLanguage.locale
        return calendar
    }

    /// The month's weeks, from the locale's first weekday, with the days either side that fill them.
    private var days: [Date] {
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let cells = Int((Double(lead + count) / 7).rounded(.up)) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - lead, to: month) }
    }

    private var isCurrentMonth: Bool { calendar.isDate(month, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        let days = days
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(20)) {
                header
                if failed {
                    Text(L("Could not load the calendar"))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                } else {
                    grid(days)
                        .pagePadding()
                    if !loading && !days.contains(where: { calendar.isDate($0, equalTo: month, toGranularity: .month) && byDay[$0] != nil }) {
                        Text(L("Nothing airs this month from your shows or watchlist."))
                            .font(Theme.font(Theme.base))
                            .foregroundStyle(Theme.gray400)
                            .pagePadding()
                    }
                }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task(id: month) { await load(days) }
        .fullScreenCover(item: $opened) { day in
            CalendarDayPanel(day: day, close: { opened = nil }) { item in
                opened = nil
                Task {
                    // The panel closes first, as one screen can't open over another closing.
                    try? await Task.sleep(for: .milliseconds(350))
                    openRoute(.item(item))
                }
            }
            .environmentObject(session)
            .environmentObject(prefs)
            .presentationBackground(.clear)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.px(12)) {
            Text(L("Calendar")).font(Theme.font(Theme.xl3, .bold))
            HStack(spacing: Theme.px(6)) {
                Button { go(-1) } label: {
                    Image(systemName: "chevron.left").accessibilityLabel(L("Previous month"))
                }
                .buttonStyle(SoftPillStyle())
                Button { go(1) } label: {
                    Image(systemName: "chevron.right").accessibilityLabel(L("Next month"))
                }
                .buttonStyle(SoftPillStyle())
            }
            .padding(.leading, Theme.px(8))
            Text(month.formatted(.dateTime.month(.wide).year().locale(AppLanguage.locale)))
                .font(Theme.font(Theme.lg, .semibold))
                .padding(.leading, Theme.px(6))
            if loading { ProgressView().scaleEffect(0.7) }
            if !isCurrentMonth {
                Button(L("Today")) { month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))! }
                    .buttonStyle(SoftPillStyle())
            }
            Spacer(minLength: 0)
        }
        .pagePadding()
        .padding(.top, Theme.px(40))
        .focusSection()
    }

    private func go(_ offset: Int) {
        if let next = calendar.date(byAdding: .month, value: offset, to: month) { month = next }
    }

    // MARK: Grid

    private func grid(_ days: [Date]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.px(8)), count: 7)
        let today = calendar.startOfDay(for: Date())
        return VStack(spacing: Theme.px(8)) {
            LazyVGrid(columns: columns, spacing: Theme.px(8)) {
                ForEach(days.prefix(7), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated).locale(AppLanguage.locale)).uppercased(with: AppLanguage.locale))
                        .font(Theme.font(Theme.xs, .semibold))
                        .tracking(Theme.px(0.5))
                        .foregroundStyle(Theme.gray400)
                        .padding(.vertical, Theme.px(4))
                }
            }
            LazyVGrid(columns: columns, spacing: Theme.px(8)) {
                ForEach(days, id: \.self) { day in
                    let items = byDay[day] ?? []
                    CalendarDayCell(day: day, items: items,
                                    outside: !calendar.isDate(day, equalTo: month, toGranularity: .month),
                                    today: day == today, shownPerDay: Self.shownPerDay) {
                        opened = CalendarDay(date: day, items: items)
                    }
                }
            }
        }
        .padding(Theme.px(8))
        .background(
            GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous),
                            fill: Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255).opacity(0.4), panel: true)
                .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: Theme.px(1)))
        )
        .focusSection()
    }

    // MARK: Loading

    private func load(_ days: [Date]) async {
        guard let client = session.client, let userId = session.userId, let first = days.first, let last = days.last else { return }
        loading = true
        failed = false
        // A day either side, for dates that arrive as midnight UTC.
        let from = calendar.date(byAdding: .day, value: -1, to: first)!
        let until = calendar.date(byAdding: .day, value: 2, to: last)!
        let iso = ISO8601DateFormatter()
        do {
            let result: ItemsResult = try await client.get("/Items", [
                "userId": userId,
                "IncludeItemTypes": "Episode,Movie",
                "Recursive": "true",
                "MinPremiereDate": iso.string(from: from),
                "MaxPremiereDate": iso.string(from: until),
                "SortBy": "PremiereDate",
                "Limit": "500",
                "Fields": "Overview",
            ])
            guard !Task.isCancelled else { return }
            var grouped: [Date: [Item]] = [:]
            for item in result.items ?? [] {
                guard let aired = airDay(item.premiereDate) else { continue }
                grouped[aired.day, default: []].append(item)
            }
            byDay = grouped
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
        loading = false
    }
}

/// A day the calendar opens, with what airs on it.
struct CalendarDay: Identifiable {
    let date: Date
    let items: [Item]
    var id: Date { date }
}

/// A title as the calendar names it: a show by its name, a film by its own.
private func calendarTitle(_ item: Item) -> String {
    (item.isEpisode ? item.seriesName : nil) ?? item.name ?? ""
}

/// Its episode number and the time it airs, as "S02E05 · 8:00 PM".
@MainActor
private func calendarDetail(_ item: Item, prefs: Preferences) -> String {
    var parts: [String] = []
    if let episode = item.indexNumber {
        let number = String(format: "E%02d", episode)
        parts.append(item.parentIndexNumber.map { String(format: "S%02d", $0) + number } ?? number)
    }
    if let timed = airDay(item.premiereDate)?.timed { parts.append(prefs.time(timed)) }
    return parts.joined(separator: " · ")
}

/// One day of the month: its number, its first title's art behind, up to two titles and how many
/// more. Focus lightens the art; choosing it lists the day.
private struct CalendarDayCell: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let day: Date
    let items: [Item]
    let outside: Bool
    let today: Bool
    let shownPerDay: Int
    let open: () -> Void

    var body: some View {
        if items.isEmpty {
            content(focused: false)
                .opacity(outside ? 0.3 : 1)
        } else {
            Button(action: open) {
                Focused { focused in
                    content(focused: focused)
                        .opacity(outside && !focused ? 0.3 : 1)
                        .modifier(FocusRing(focused: focused, radius: Theme.px(10)))
                        .scaleEffect(focused ? 1.04 : 1)
                        .animation(.easeOut(duration: 0.15), value: focused)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func content(focused: Bool) -> some View {
        let listed = Array(items.prefix(shownPerDay))
        let extra = items.count - listed.count
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous)
                .fill(Color.white.opacity(focused ? 0.06 : 0.03))
            if let first = items.first {
                RemoteImage(url: session.client?.still(first, height: 360) ?? session.client?.backdrop(first, height: 360))
                    .opacity(today ? 0.85 : focused ? 0.65 : 0.5)
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255), location: 0),
                        .init(color: Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255).opacity(0.7), location: 0.35),
                        .init(color: .clear, location: 0.7),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(Calendar.current.component(.day, from: day))")
                    .font(Theme.font(Theme.sm, .semibold))
                    .foregroundStyle(today ? Color.white : Theme.gray200)
                    .shadow(color: .black.opacity(today ? 0 : 0.8), radius: Theme.px(3), y: Theme.px(1))
                    .frame(width: Theme.px(28), height: Theme.px(28))
                    .background(Circle().fill(today ? Theme.brand500 : .clear))
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: Theme.px(4)) {
                    ForEach(listed) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(calendarTitle(item))
                                .font(Theme.font(Theme.sm, .medium))
                                .foregroundStyle(item.userData?.played == true ? Theme.gray400 : Theme.gray200)
                                .lineLimit(1)
                            let detail = calendarDetail(item, prefs: prefs)
                            if !detail.isEmpty {
                                Text(detail).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).lineLimit(1)
                            }
                        }
                    }
                    if extra > 0 {
                        Text(L("+%@ more", String(extra))).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
                    }
                }
            }
            .padding(Theme.px(8))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.px(160))
        .clipShape(RoundedRectangle(cornerRadius: Theme.px(10), style: .continuous))
    }
}

/// A day's whole list, as the web app's day dialog: each title's still, name, episode and time.
/// Choosing one opens its page.
private struct CalendarDayPanel: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let day: CalendarDay
    let close: () -> Void
    let choose: (Item) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                Text(day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.locale)))
                    .font(Theme.font(Theme.xl, .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.px(4)) {
                        ForEach(day.items) { item in
                            Button { choose(item) } label: {
                                HStack(spacing: Theme.px(12)) {
                                    RemoteImage(url: session.client?.still(item, height: 240) ?? session.client?.backdrop(item, height: 240))
                                        .frame(width: Theme.px(112), height: Theme.px(63))
                                        .background(Theme.gray900)
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
                                    VStack(alignment: .leading, spacing: Theme.px(2)) {
                                        Text(calendarTitle(item)).font(Theme.font(Theme.base, .medium)).lineLimit(1)
                                        let detail = [item.isEpisode ? item.name : nil, calendarDetail(item, prefs: prefs)]
                                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                                        if !detail.isEmpty {
                                            Text(detail).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(Theme.px(6))
                                .foregroundStyle(item.userData?.played == true ? Theme.gray400 : .white)
                            }
                            .buttonStyle(RowStyle(radius: Theme.px(12)))
                        }
                    }
                    .padding(Theme.px(8))
                }
                .frame(maxHeight: Theme.px(560))
            }
            .padding(Theme.px(28))
            .frame(width: Theme.px(620))
            .background(
                GlassBackground(shape: RoundedRectangle(cornerRadius: Theme.px(18), style: .continuous),
                                fill: Color(red: 3 / 255, green: 7 / 255, blue: 18 / 255).opacity(0.95), panel: true)
                    .overlay(RoundedRectangle(cornerRadius: Theme.px(18), style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: Theme.px(1)))
            )
        }
        .onExitCommand(perform: close)
    }
}

// MARK: - Activity

struct HistoryEntry: Decodable {
    var kind: String?
    var played: Bool?
    var positionMs: Double?
    var durationMs: Double?
    var lastPlayedAt: Double?
    var sortAt: Double?
    var item: Item
}

struct HistoryPage: Decodable {
    var items: [HistoryEntry]
    var cursor: String?
}

struct ActivityView: View {
    @EnvironmentObject private var session: Session
    @State private var entries: [HistoryEntry] = []
    @State private var cursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var choice: VersionChoice?

    /// Days in order; within a day, one card a show, its latest episode.
    private var days: [(Date?, [Item])] {
        var order: [Date?] = []
        var byDay: [Date?: [Item]] = [:]
        var seen: [Date?: Set<String>] = [:]
        for entry in entries {
            let when = (entry.lastPlayedAt ?? entry.sortAt).map { Date(timeIntervalSince1970: $0 / 1000) }
            let day = when.map { Calendar.current.startOfDay(for: $0) }
            if byDay[day] == nil { order.append(day); byDay[day] = [] }
            let key = entry.item.isEpisode ? (entry.item.seriesId ?? entry.item.id) : entry.item.id
            if seen[day, default: []].insert(key).inserted { byDay[day]?.append(entry.item) }
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.px(32)) {
                PageTitle(text: L("Activity"))
                if loaded && entries.isEmpty {
                    Text(L("What you watch shows here."))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .focusable()
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    DayRow(title: day.0.map(dayName) ?? L("Earlier"), detail: nil, items: day.1) { item in
                        Task { choice = await playChoice(for: item, session: session) }
                    }
                    .onAppear { if index == days.count - 1 { Task { await more() } } }
                }
                if loading && loaded { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { if !loaded { await more() } }
        .refreshOnReturn {
            entries = []
            cursor = nil
            loaded = false
            await more()
        }
        .reloadOnWatchChange {
            entries = []
            cursor = nil
            loaded = false
            await more()
        }
        .playFlow($choice)
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && cursor == nil { return }
        loading = true
        defer { loading = false }
        let page: HistoryPage? = try? await client.get("/AIOStreams/History", ["userId": userId, "cursor": cursor])
        entries.append(contentsOf: page?.items ?? [])
        cursor = page?.cursor
        loaded = true
    }
}
