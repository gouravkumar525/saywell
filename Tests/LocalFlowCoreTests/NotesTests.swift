import XCTest
@testable import LocalFlowCore

/// C5: from two recordings to a transcript by speaker, and the summary.
final class NotesTests: XCTestCase {
    func words(_ s: String, from start: Double, step: Double = 0.4) -> [TimedWord] {
        s.split(separator: " ").enumerated().map { TimedWord(String($1), start + Double($0) * step, start + Double($0) * step + 0.3) }
    }

    func testEchoRunsAreDroppedButSingleMatchesKept() {
        let system = words("so the budget is final now", from: 10)
        let mic = words("okay", from: 2) + words("so the budget is final", from: 10.3) + words("yes the plan", from: 20)
        let mine = NoteBuilder.removingEcho(mic: mic, system: system)
        XCTAssertEqual(mine.map(\.text), ["okay", "yes", "the", "plan"])
        XCTAssertEqual(NoteBuilder.removingEcho(mic: words("the", from: 10), system: system).count, 1, "one shared word is not echo")
    }

    func testFragmentsMergeIntoNearestSolidVoice() {
        let turns = [SpeakerTurn("A", 0, 10), SpeakerTurn("C", 10.2, 10.9), SpeakerTurn("B", 30, 45)]
        let merged = NoteBuilder.mergingFragments(turns)
        XCTAssertEqual(merged.map(\.speaker), ["A", "A", "B"])
    }

    func testBuildLabelsMeAndPeopleInOrder() {
        let mic = words("hi everyone", from: 0)
        let system = words("hello there", from: 3) + words("good morning", from: 8)
        let turns = [SpeakerTurn("spk_1", 2.5, 4.5), SpeakerTurn("spk_0", 7.5, 9.5)]
        let (speakers, lines) = NoteBuilder.build(mic: mic, system: system, systemTurns: turns)
        XCTAssertEqual(speakers.map(\.name), ["Me", "Person 2", "Person 3"])
        XCTAssertEqual(lines.map(\.text), ["hi everyone", "hello there", "good morning"])
        XCTAssertEqual(lines.map(\.speaker), ["me", "p2", "p3"])
    }

    func testRoomRecordingSplitsTheMic() {
        let mic = words("we agreed", from: 0) + words("on friday", from: 5)
        let (speakers, lines) = NoteBuilder.build(mic: mic, system: [], systemTurns: [],
                                                  micTurns: [SpeakerTurn("x", 0, 4), SpeakerTurn("y", 4.5, 9)])
        XCTAssertEqual(speakers.map(\.name), ["Person 1", "Person 2"])
        XCTAssertFalse(speakers.contains { $0.isMe })
        XCTAssertEqual(lines.count, 2)
    }

    func testLinesBreakOnPauseAndLength() {
        let w = words("one two", from: 0) + words("three", from: 5)
        XCTAssertEqual(NoteBuilder.lines(w.map { ($0, "me") }).map(\.text), ["one two", "three"])
        let long = (0..<120).map { TimedWord("w", Double($0) * 0.5, Double($0) * 0.5 + 0.3) }
        XCTAssertGreaterThan(NoteBuilder.lines(long.map { ($0, "me") }).count, 1, "no line runs past 40 s")
    }

    func testRenameToAnotherNameMerges() {
        var note = Note(title: "t", start: Date(), status: .ready)
        note.speakers = [NoteSpeaker(id: "p2", name: "Person 2"), NoteSpeaker(id: "p3", name: "Sarah")]
        note.lines = [NoteLine(speaker: "p3", start: 0, end: 1, text: "hi"), NoteLine(speaker: "p2", start: 1.2, end: 2, text: "there")]
        NoteBuilder.rename(&note, speaker: "p2", to: "sarah")
        XCTAssertEqual(note.speakers.map(\.name), ["Sarah"])
        XCTAssertEqual(note.lines.map(\.text), ["hi there"])
        NoteBuilder.rename(&note, speaker: "p3", to: "Sarah Lee")
        XCTAssertEqual(note.speakers.first?.name, "Sarah Lee")
    }

    func testSummaryParsing() {
        let out = """
            Here you go:
            ```json
            {"title": "Budget sync", "summary": "We agreed the budget.", "key_points": ["Budget final", ""],
             "todos": [{"text": "Send the invoice", "owner": "Sarah", "due": "Friday"}, {"text": "Book room", "owner": null, "due": "null"}]}
            ```
            """
        let r = NoteSummary.parse(out)
        XCTAssertEqual(r?.title, "Budget sync")
        XCTAssertEqual(r?.keyPoints, ["Budget final"])
        XCTAssertEqual(r?.todos.map(\.owner), ["Sarah", nil])
        XCTAssertNil(r?.todos.last?.due)
        XCTAssertNil(NoteSummary.parse("I can't do that"))
    }

    func testPartsSplitBetweenLines() {
        let transcript = (0..<10).map { _ in "Me: " + String(repeating: "word ", count: 100) }.joined(separator: "\n")
        let parts = NoteBuilder.parts(transcript, words: 350)
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("Me:") })
    }

    func testMarkdownAndStoreRoundTrip() throws {
        var note = Note(title: "Weekly", start: Date(timeIntervalSince1970: 0), status: .ready)
        note.end = Date(timeIntervalSince1970: 600)
        note.speakers = [NoteSpeaker(id: "me", name: "Me", isMe: true)]
        note.lines = [NoteLine(speaker: "me", start: 65, end: 67, text: "Let's ship it.")]
        note.summary = "Shipping."
        note.todos = [NoteTodo(text: "Ship", owner: "Me", done: true)]
        let md = NoteBuilder.markdown(note)
        XCTAssertTrue(md.contains("# Weekly"))
        XCTAssertTrue(md.contains("- [x] Ship (Me)"))
        XCTAssertTrue(md.contains("**Me** (1:05): Let's ship it."))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        store.saveNote(note)
        note.title = "Weekly sync"
        store.saveNote(note)
        XCTAssertEqual(store.notes(), [note])
        store.deleteNote(id: note.id)
        XCTAssertTrue(store.notes().isEmpty)
    }
}

final class NoteAssignTests: XCTestCase {
    func testLateLastWordStaysWithItsSpeaker() {
        // Seen live: "afternoon" timed 3 s after its speaker's turn ended.
        let turns = [SpeakerTurn("S1", 5.9, 11.1), SpeakerTurn("S2", 11.8, 15.0), SpeakerTurn("S1", 20.3, 25.1)]
        let words = [TimedWord("Wednesday", 14.2, 14.7), TimedWord("afternoon", 17.6, 18.2)]
        XCTAssertEqual(NoteBuilder.assign(words, to: turns, fallback: "other").map(\.1), ["S2", "S2"])
        XCTAssertEqual(NoteBuilder.assign(words, to: [], fallback: "other").map(\.1), ["other", "other"])
    }
}

final class MeetingNotesTests: XCTestCase {
    func testMeetingStartsAfterAHoldAndEndsAfterAGap() {
        var d = MeetingDetector()
        XCTAssertNil(d.update(micUsers: ["com.apple.Safari"], at: 0))
        XCTAssertNil(d.update(micUsers: ["us.zoom.xos"], at: 1))
        XCTAssertNil(d.update(micUsers: ["us.zoom.xos"], at: 3), "an audio test is not a meeting")
        XCTAssertEqual(d.update(micUsers: ["us.zoom.xos", "com.gourav.saywell"], at: 5.5), .started("Zoom"))
        XCTAssertNil(d.update(micUsers: ["us.zoom.xos"], at: 60))
        XCTAssertNil(d.update(micUsers: [], at: 65), "a short drop doesn't end it")
        XCTAssertNil(d.update(micUsers: ["us.zoom.xos"], at: 70))
        XCTAssertNil(d.update(micUsers: [], at: 75))
        XCTAssertEqual(d.update(micUsers: [], at: 83), .ended("Zoom"))
        XCTAssertNil(d.update(micUsers: [], at: 90))
    }

    func testRecognisesTeamsAndWebex() {
        XCTAssertEqual(MeetingDetector.meetingApp(["com.microsoft.teams2"]), "Teams")
        XCTAssertEqual(MeetingDetector.meetingApp(["com.cisco.webexmeetingsapp"]), "Webex")
        XCTAssertNil(MeetingDetector.meetingApp(["com.tinyspeck.slackmacgap", "com.apple.FaceTime"]))
    }

    func testRicherSummaryParsing() {
        let r = NoteSummary.parse("""
            {"title": "Launch", "summary": "We planned the launch.", "key_points": ["Page ready"],
             "decisions": ["Launch on Monday"], "open_questions": ["Who writes the blog post?"],
             "action_items": [{"text": "Send pricing", "owner": "Karen", "due": "Wednesday"}]}
            """)
        XCTAssertEqual(r?.decisions, ["Launch on Monday"])
        XCTAssertEqual(r?.openQuestions, ["Who writes the blog post?"])
        XCTAssertEqual(r?.todos.first?.owner, "Karen")
    }

    func testOldNotesStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","titleEdited":false,"start":"2026-10-29T10:00:00Z","status":"ready","speakers":[],"lines":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F0","speaker":"me","start":0,"end":1,"text":"hi"}],"liveLines":[],"keyPoints":[],"todos":[]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let note = try d.decode(Note.self, from: Data(json.utf8))
        XCTAssertNil(note.decisions)
        XCTAssertNil(note.lines.first?.raw)
    }
}
