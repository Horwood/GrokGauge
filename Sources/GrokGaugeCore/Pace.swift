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
                               minimumElapsed: TimeInterval = 12 * 3600) -> PaceStatus {
        guard percent.isFinite, periodEnd > periodStart else { return .tooEarly }
        if percent >= 100 { return .exhausted }
        let elapsed = now.timeIntervalSince(periodStart)
        let remaining = periodEnd.timeIntervalSince(now)
        guard remaining > 0 else { return .onTrack(projected: max(0, percent)) }
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

    /// "On track (≈35% at reset)" / "At this pace you'll hit 100% by Fri 3 PM".
    public static func describe(_ status: PaceStatus, timeZone: TimeZone = .current) -> String {
        switch status {
        case .tooEarly: return "Pace: too early to tell"
        case .onTrack(let p): return "On track (≈\(Int(p.rounded()))% at reset)"
        case .exhausted: return "Limit reached"
        case .runsOut(let date):
            let f = DateFormatter()
            f.timeZone = timeZone
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("EEE j")
            return "At this pace you'll hit 100% by \(f.string(from: date))"
        }
    }
}
