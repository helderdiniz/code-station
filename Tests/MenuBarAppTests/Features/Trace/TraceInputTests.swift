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
}
