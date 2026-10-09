import AppKit
import GrokGaugeCore
import SwiftUI

// MARK: - Dropdown section

struct WhatsNewCard: View {
    @ObservedObject var store: WhatsNewStore
    let settings: WhatsNewSettings
    let now: Date

    @ViewState var expanded = false

    private var all: [NewsItem] { store.state.latest(enabled: settings.enabled, limit: WhatsNewSettings.expandedItems) }
    private var items: [NewsItem] { expanded ? all : Array(all.prefix(WhatsNewSettings.compactItems)) }
    private var unread: Int { store.state.unread(enabled: settings.enabled).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("What's new from xAI")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                if unread > 0 {
                    Text("\(unread)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel("\(unread) unread")
                }
                Spacer()
                if unread > 0 {
                    Button("Mark all read") { store.markAllRead() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if items.isEmpty {
                Text(store.state.items.isEmpty
                     ? "Nothing yet. GrokGauge checks xAI's public pages about every \(settings.interval.rawValue) hours."
                     : "No items from the sources you chose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        WhatsNewRow(item: item, unread: store.isUnread(item), now: now,
                                    open: { store.open(item) }, copy: { store.copyCommand(item) })
                    }
                }
            }
            HStack(spacing: 10) {
                if all.count > WhatsNewSettings.compactItems {
                    Button(expanded ? "Show less" : "Show more (\(all.count - WhatsNewSettings.compactItems))") {
                        expanded.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .accessibilityLabel(expanded ? "Show fewer What's new items" : "Show more What's new items")
                }
                Text("On X:").font(.caption2).foregroundStyle(.tertiary)
                Link("@xai", destination: NewsLinks.xaiProfile).font(.caption2)
                Link("@grok", destination: NewsLinks.grokProfile).font(.caption2)
                Spacer()
            }
            .accessibilityElement(children: .contain)
        }
    }
}

private struct WhatsNewRow: View {
    let item: NewsItem
    let unread: Bool
    let now: Date
    let open: () -> Void
    let copy: () -> Void
    @ViewState var hovering = false
    @ViewState var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.source.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.caption.weight(unread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let command = item.command {
                    HStack(spacing: 6) {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
                        Button(copied ? "Copied" : "Copy") {
                            copy()
                            copied = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .help("Copy “\(command)”, then paste it in Terminal. GrokGauge never runs it.")
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            if item.opensGrokBot {
                Button("Open") { open() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Open Grok Bot")
            }
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .opacity(unread ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(hovering && item.url != nil ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if item.url != nil || item.opensGrokBot { open() } }
        .help(item.detail ?? item.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unread ? "Unread. " : "")\(item.title). \(subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var subtitle: String {
        guard let d = item.date else { return item.source.shortName }
        return "\(item.source.shortName) · \(Self.dateText(d, monthOnly: item.monthOnly, now: now))"
    }

    static func dateText(_ d: Date, monthOnly: Bool, now: Date) -> String {
        if monthOnly {
            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "UTC")!
            let sameYear = cal.component(.year, from: d) == cal.component(.year, from: now)
            let f = DateFormatter()
            f.timeZone = cal.timeZone
            f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
            return f.string(from: d)
        }
        if now.timeIntervalSince(d) < 60 { return "just now" }
        if now.timeIntervalSince(d) < 7 * 86_400 {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return f.localizedString(for: d, relativeTo: now)
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Settings tab

struct WhatsNewPrefs: View {
    @Binding var settings: GaugeSettings
    @ObservedObject var store: WhatsNewStore

    var body: some View {
        Group {
            PrefGroup(title: "Dropdown",
                      footer: "Shows the 3 newest items (Show more for up to 8). A dot marks items you haven't opened; the first check marks everything already out as read.") {
                Toggle("Show “What's new from xAI” in the dropdown", isOn: Binding(
                    get: { settings.isVisible(.whatsNew) },
                    set: { on in
                        if let i = settings.sections.firstIndex(where: { $0.id == .whatsNew }) { settings.sections[i].visible = on }
                    }))
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: unreadLabel) {
                    Button("Mark All Read") { store.markAllRead() }
                        .disabled(store.state.items.isEmpty)
                }
            }
            PrefGroup(title: "Sources") {
                ForEach(Array(NewsSource.allCases.enumerated()), id: \.element) { index, src in
                    if index > 0 { Divider() }
                    Toggle(isOn: Binding(get: { settings.whatsNew.isOn(src) },
                                         set: { settings.whatsNew.set(src, $0) })) {
                        HStack(spacing: 8) {
                            Image(systemName: src.symbol).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(src.title)
                                Text(src.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityLabel(src.title)
                    .accessibilityHint(src.detail)
                }
            }
            PrefGroup(title: "Checking & notifications",
                      footer: "No login or API key. GrokGauge asks x.ai, docs.x.ai, storage.googleapis.com (Grok CLI mirror) and itunes.apple.com, identifying itself as “GrokGauge/\(AppInfo.version) (macOS menu bar)”. The Grok CLI version and Grok Bot's version are read from files on this Mac. GrokGauge never installs anything: for the CLI it gives you the `grok update` command to copy.") {
                PrefRow(label: "Check for news", detail: "The Grok CLI is checked every 2 hours") {
                    Picker("", selection: $settings.whatsNew.interval) {
                        ForEach(WhatsNewInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Divider()
                Toggle("Notify me about new items (one summary per check)", isOn: $settings.whatsNew.notify)
                    .padding(.vertical, 6)
                Divider()
                PrefRow(label: lastCheckedLabel) {
                    if store.isChecking { ProgressView().controlSize(.small) }
                    Button("Check Now") { store.checkDue(force: true) }
                        .disabled(store.isChecking || settings.whatsNew.enabled.isEmpty)
                }
            }
            PrefGroup(title: "On X", footer: "GrokGauge doesn't read X (that needs an account); these open the profiles.") {
                PrefRow(label: "xAI") { Link("x.com/xai", destination: NewsLinks.xaiProfile) }
                Divider()
                PrefRow(label: "Grok") { Link("x.com/grok", destination: NewsLinks.grokProfile) }
            }
        }
    }

    private var unreadLabel: String {
        let n = store.state.unread(enabled: settings.whatsNew.enabled).count
        return n == 0 ? "All caught up" : n == 1 ? "1 unread item" : "\(n) unread items"
    }

    private var lastCheckedLabel: String {
        let dates = NewsSource.allCases.filter { $0.isRemote && settings.whatsNew.isOn($0) }
            .compactMap { store.state.state($0).lastSuccess }
        guard let d = dates.max() else { return "Not checked yet" }
        return "Last checked \(d.formatted(date: .abbreviated, time: .shortened))"
    }
}
