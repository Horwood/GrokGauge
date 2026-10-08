import Foundation
import Testing
@testable import GrokGaugeCore

@Suite struct UsageParserTests {
    @Test func parsesFullPayload() throws {
        let json = """
        {"config":{
          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",
            "start":"2026-10-06T20:57:54.858014+00:00","end":"2026-10-13T20:57:54.858014+00:00"},
          "creditUsagePercent":42.5,
          "onDemandCap":{"val":5000},"onDemandUsed":{"val":"250"},"prepaidBalance":{"val":1446},
          "productUsage":[{"product":"GrokChat","usagePercent":30},{"product":"GrokBuild","usagePercent":12.5},
                          {"product":"GrokAppBuilder"}]
        }}
        """
        let s = try UsageParser.parse(Data(json.utf8))
        #expect(s.percent == 42.5)
        #expect(!s.percentInferred)
        #expect(s.roundedPercent == 43)
        #expect(s.period == .weekly)
        #expect(s.prepaidBalanceCents == 1446)
        #expect(s.onDemandUsedCents == 250)
        #expect(s.onDemandCapCents == 5000)
        #expect(s.periodEnd == ISODate.parse("2026-10-13T20:57:54.858Z"))
        #expect(s.products.map(\.name) == ["Chat", "Imagine", "Voice", "Build", "API", "App Builder"])
        #expect(s.products.first { $0.name == "Chat" }?.percent == 30)
        #expect(s.products.first { $0.name == "Build" }?.percent == 12.5)
    }

    @Test func missingPercentMeansZero() throws {
        // Real shape seen right after a weekly reset: proto3 omits zero scalars.
        let json = """
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-06T20:57:54.858014+00:00",
          "end":"2026-10-13T20:57:54.858014+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},
          "isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}
        """
        let s = try UsageParser.parse(Data(json.utf8))
        #expect(s.percent == 0)
        #expect(s.percentInferred)
        #expect(s.products.count == 5)
        #expect(!s.hasExtraCredits)
    }

    @Test func fallsBackToBillingPeriodEnd() throws {
        let json = #"{"config":{"creditUsagePercent":5,"billingPeriodEnd":"2026-10-13T20:57:54Z"}}"#
        let s = try UsageParser.parse(Data(json.utf8))
        #expect(s.periodEnd != nil)
        #expect(s.period == .unknown)
    }

    @Test func rejectsGarbage() {
        #expect(throws: UsageParserError.notJSON) { try UsageParser.parse(Data("<html>".utf8)) }
        #expect(throws: UsageParserError.missingConfig) { try UsageParser.parse(Data("{}".utf8)) }
    }

    @Test func detectsUnexpectedShape() {
        // Missing period: the "missing percent = 0%" rule must not kick in.
        #expect(throws: UsageParserError.missingPeriod) {
            try UsageParser.parse(Data(#"{"config":{"isUnifiedBillingUser":true}}"#.utf8))
        }
        #expect(throws: UsageParserError.missingPeriod) {
            try UsageParser.parse(Data(#"{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"X"}}}"#.utf8))
        }
        // Renamed top level.
        #expect(throws: UsageParserError.missingConfig) {
            try UsageParser.parse(Data(#"{"billingConfig":{"creditUsagePercent":3}}"#.utf8))
        }
        // Known field with a new type.
        #expect(throws: UsageParserError.unexpectedTypes) {
            try UsageParser.parse(Data(#"{"config":{"currentPeriod":"weekly"}}"#.utf8))
        }
        // A JSON array isn't the billing object either, but it's not a shape we can talk about.
        #expect(throws: UsageParserError.notJSON) { try UsageParser.parse(Data("[1,2]".utf8)) }
        #expect(UsageParserError.missingPeriod.isShapeChange)
        #expect(!UsageParserError.notJSON.isShapeChange)
    }

    @Test func colorThresholds() {
        #expect(UsageLevel.forPercent(0) == .normal)
        #expect(UsageLevel.forPercent(80) == .normal)
        #expect(UsageLevel.forPercent(81) == .warning)
        #expect(UsageLevel.forPercent(90) == .warning)
        #expect(UsageLevel.forPercent(91) == .critical)
        #expect(UsageLevel.forPercent(100) == .critical)
    }

    @Test func displayNames() {
        #expect(UsageParser.displayName(for: "GrokAppBuilder") == "App Builder")
        #expect(UsageParser.displayName(for: "PRODUCT_TYPE_DEEP_SEARCH") == "Deep Search")
    }

    @Test func countdown() {
        #expect(UsageFormat.countdown(5 * 86_400 + 19 * 3_600 + 120) == "5 days, 19 hr")
        #expect(UsageFormat.countdown(3_600 + 240) == "1 hr, 4 min")
        #expect(UsageFormat.wholeDays(6.9 * 86_400) == 6)
    }
}

@Suite struct AuthStoreTests {
    let now = ISODate.parse("2026-10-07T12:00:00Z")!

    @Test func picksValidSuperGrokEntry() throws {
        let json = """
        {"https://accounts.x.ai/sign-in::a":{"key":"old","expires_at":"2026-10-01T00:00:00Z"},
         "https://auth.x.ai::b":{"key":" tok ","expires_at":"2026-10-08T07:37:02.380497Z","email":"me@example.com",
           "oidc_issuer":"https://auth.x.ai","oidc_client_id":"b","refresh_token":"rt"}}
        """
        let c = try AuthStore.select(fromJSON: Data(json.utf8), now: now)
        #expect(c.token == "tok")
        #expect(c.email == "me@example.com")
        #expect(c.canRefresh)
        #expect(c.description.contains("<redacted>"))
        #expect(!c.description.contains("tok\""))
    }

    @Test func expiredEntryIsStillReturnedForRenewal() throws {
        let json = #"{"https://auth.x.ai::cid":{"key":"tok","refresh_token":"rt","expires_at":"2026-10-07T11:00:00Z"}}"#
        let c = try AuthStore.select(fromJSON: Data(json.utf8), now: now)
        #expect(c.isExpired(now: now))
        #expect(c.issuer == "https://auth.x.ai")     // derived from the scope key
        #expect(c.clientID == "cid")
    }

    @Test func emptyFileIsSignedOut() {
        #expect(throws: AuthError.notSignedIn) { try AuthStore.select(fromJSON: Data("{}".utf8), now: now) }
    }
}
