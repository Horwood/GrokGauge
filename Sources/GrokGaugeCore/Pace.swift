import Foundation

public enum PaceStatus: Equatable, Sendable {
    /// Not enough of the period has passed to project anything.
    case tooEarly
    /// The pool won't run out before the reset; `projected` is the expected percent at reset.
    case onTrack(projected: Double)
    /// At the current rate, the pool hits 100% at `date` (before the reset).
    case runsOut(at: Date)
    /// Already at or above 100%.
    case exhausted
}

public enum Pace {
    /// Linear projection from usage since the period started. Waits `minimumElapsed` (12 h) first:
    /// a few busy hours early in the week would otherwise predict running out in a day or two.
    public static func project(percent: Double, periodStart: Date, periodEnd: Date, now: Date = Date(),
                               minimumElapsed: TimeInterval = 12 * 3600, recent: BurnRate? = nil) -> PaceStatus {
        guard percent.isFinite, periodEnd > periodStart else { return .tooEarly }
        if percent >= 100 { return .exhausted }
        let elapsed = now.timeIntervalSince(periodStart)
        let remaining = periodEnd.timeIntervalSince(now)
        guard remaining > 0 else { return .onTrack(projected: max(0, percent)) }
        // A measured slope replaces the week average. No slope (no history yet) keeps the old rule,
        // including the 12-hour wait.
        if let recent, recent.perSecond.isFinite {
            if recent.perSecond <= 0 || percent <= 0 { return .onTrack(projected: max(0, percent)) }
            let projected = percent + recent.perSecond * remaining
            if projected < 100 { return .onTrack(projected: projected) }
            return .runsOut(at: now.addingTimeInterval((100 - percent) / recent.perSecond))
        }
        if percent <= 0 { return elapsed >= minimumElapsed ? .onTrack(projected: 0) : .tooEarly }
        guard elapsed >= minimumElapsed else { return .tooEarly }
        let rate = percent / elapsed                       // percent per second
        let projected = percent + rate * remaining
        if projected < 100 { return .onTrack(projected: projected) }
        return .runsOut(at: now.addingTimeInterval((100 - percent) / rate))
    }

    /// Grok Bot only reports the next reset; its weekly window starts 7 days earlier.
    public static func weeklyStart(forReset reset: Date) -> Date {
        reset.addingTimeInterval(-7 * 86_400)
    }

    /// "On track (≈35% at reset)" / "At this pace: 100% by Fri, Oct 30".
    public static func describe(_ status: PaceStatus, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch status {
        case .tooEarly: return "Pace: too early to tell"
        case .onTrack(let p): return "On track (≈\(Int(p.rounded()))% at reset)"
        case .exhausted: return "Limit reached"
        case .runsOut(let date):
            return "At this pace: 100% by \(PaceWarning.day(date, timeZone: timeZone, locale: locale))"
        }
    }

    /// The warning for the Resets in card, only when the pace hits 100% before the reset (nil otherwise).
    public static func warning(_ status: PaceStatus?, cause: String? = nil, now: Date = Date(), timeZone: TimeZone = .current,
                               locale: Locale = .current) -> PaceWarning? {
        guard case .runsOut(let at)? = status else { return nil }
        return PaceWarning(at: at, now: now, timeZone: timeZone, locale: locale, cause: cause)
    }
}

/// "On pace to run out" text, worded and laid out like the reset line it sits under:
///
///     RESETS IN   2 days          2 days, 19 hr
///                                 Mon, Oct 26 at 6:32 PM EDT
///     ⚠ At this pace         100% by Sun, Oct 25
///                            in 1 day, 8 hr · about 3 AM EDT
public struct PaceWarning: Equatable, Sendable {
    public let at: Date
    /// "100% by Sun, Oct 25" (the main line: the day is the point, not the minute).
    public let headline: String
    /// "in 1 day, 8 hr · about 3 AM EDT" (same countdown style as the reset line).
    public let detail: String
    /// "At this pace: 100% by Sun, Oct 25" (one line, for VoiceOver and the tour).
    public let sentence: String

    public init(at: Date, now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                cause: String? = nil) {
        self.at = at
        let day = Self.day(at, timeZone: timeZone, locale: locale)
        headline = "100% by \(day)"
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("j z")
        detail = "in \(UsageFormat.countdown(at.timeIntervalSince(now))) · about \(f.string(from: at))"
        sentence = "At this pace: \(headline)"
        if let cause, !cause.isEmpty {
            detail += " · mostly \(cause)"
            sentence += ", mostly \(cause)"
        }
    }

    /// "Sun, Oct 25": weekday plus date, so it's never just an ambiguous weekday.
    public static func day(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f.string(from: date)
    }
}
