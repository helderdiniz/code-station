import Foundation
import Testing
@testable import MenuBarApp

struct TraceInputTests {
    private static let id = "0af7651916cd43dd8448eb211c80319c"

    @Test func takesATraceIdAsTyped() {
        #expect(TraceInput.traceID(from: "  0AF7651916CD43DD8448EB211C80319C \n") == Self.id)
        #expect(TraceInput.traceID(from: "b7ad6b7169203331") == "b7ad6b7169203331")
    }

    @Test func pullsTheTraceIdOutOfAGrafanaLink() {
        let explore = "https://grafana.edge-prd.example.com/explore?schemaVersion=1&panes=%7B%22a%22%3A%7B%22datasource%22%3A%22P214B5B846CF3925F%22%2C%22queries%22%3A%5B%7B%22query%22%3A%220af7651916cd43dd8448eb211c80319c%22%7D%5D%7D%7D"
        #expect(TraceInput.traceID(from: explore) == Self.id)
        #expect(TraceInput.traceID(from: "https://grafana.example.com/trace/\(Self.id)?orgId=1") == Self.id)
    }

    // Tempo search hands back an id that starts with a zero without it.
    @Test func putsBackTheLeadingZeroTempoSearchDrops() {
        #expect(TraceInput.traceID(from: String(Self.id.dropFirst())) == Self.id)
        #expect(TraceInput.traceID(from: "https://grafana.example.com/trace/\(Self.id.dropFirst())") == Self.id)
    }

    @Test func rejectsWhatIsNotATraceId() {
        #expect(TraceInput.traceID(from: "") == nil)
        #expect(TraceInput.traceID(from: "hello") == nil)
        #expect(TraceInput.traceID(from: String(Self.id.dropLast(2))) == nil)
        #expect(TraceInput.traceID(from: Self.id + "a") == nil)
        #expect(TraceInput.traceID(from: "https://grafana.example.com/explore") == nil)
    }

    @Test func findsTraceIdsInFreeText() {
        #expect(TraceInput.traceIDs(in: "Checkout fails, trace \(Self.id.uppercased()).") == [Self.id])
        #expect(TraceInput.traceIDs(in: "See https://grafana.example.com/trace/\(Self.id)?orgId=1 twice: \(Self.id)") == [Self.id])
        #expect(TraceInput.traceIDs(in: "Tempo shows \(Self.id.dropFirst())") == [Self.id])
        #expect(TraceInput.traceIDs(in: "Old tracer id b7ad6b7169203331 failed") == ["b7ad6b7169203331"])
    }

    @Test func findsTheTraceIdInAnEncodedGrafanaLinkInText() {
        let explore = "https://grafana.edge-prd.example.com/explore?schemaVersion=1&panes=%7B%22a%22%3A%7B%22datasource%22%3A%22P214B5B846CF3925F%22%2C%22queries%22%3A%5B%7B%22query%22%3A%22\(Self.id)%22%7D%5D%7D%7D"
        #expect(TraceInput.traceIDs(in: "About 50% of payments fail: \(explore)") == [Self.id])
    }

    // A span id sits beside the trace id in many links, and is not a trace of its own.
    @Test func ignoresShortIdsWhenAFullOneIsNamed() {
        #expect(TraceInput.traceIDs(in: "/trace/\(Self.id)?spanId=b7ad6b7169203331") == [Self.id])
    }

    @Test func findsNoTraceIdInOrdinaryText() {
        #expect(TraceInput.traceIDs(in: "").isEmpty)
        #expect(TraceInput.traceIDs(in: "Checkout fails for card 4111111111111111 since 10:00").isEmpty)
        #expect(TraceInput.traceIDs(in: "Commit 9fceb02d0ae598e95dc970b74767f19372d61af8 broke it").isEmpty)
        #expect(TraceInput.traceIDs(in: "Request 3f2504e0-4f89-11d3-9a0c-0305e82c3301 failed").isEmpty)
        #expect(TraceInput.traceIDs(in: "Datasource P214B5B846CF3925F is down").isEmpty)
    }
}
