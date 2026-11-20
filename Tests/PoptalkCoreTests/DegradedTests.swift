import Foundation
import Testing
@testable import PoptalkCore

@Test func runModeFollowsReadiness() {
    #expect(RunMode(speech: .ready, llm: .ready) == .full)
    #expect(RunMode(speech: .ready, llm: .loading) == .raw("raw — model loading"))
    #expect(RunMode(speech: .ready, llm: .downloading(0.5)) == .raw("raw — downloading model 50%"))
    #expect(RunMode(speech: .loading, llm: .ready) == .noSpeech("Speech model loading…"))
    #expect(RunMode(speech: .downloading(0.42), llm: .loading) == .noSpeech("Downloading speech model 42%"))
    #expect(RunMode(speech: .failed("disk"), llm: .ready) == .noSpeech("Speech model failed to load (retrying): disk"))
}

private func raw() -> RawInsert {
    RawInsert(request: Request(transcript: "um hello", selection: nil, context: ScreenSnapshot()),
              rawTranscript: "um hello", boost: [], prefix: " ", fieldValue: "Hi hello")
}

@Test func cleanupOfferValidOnlyWhileFieldFocusedAndUnchanged() {
    let last = LastInsert(target: "slack", text: "hello", reprocess: raw())
    #expect(last.canReprocess(focused: "slack", value: "Hi hello"))
    #expect(!last.canReprocess(focused: "mail", value: "Hi hello"))
    #expect(!last.canReprocess(focused: nil, value: "Hi hello"))
    #expect(!last.canReprocess(focused: "slack", value: "Hi hello!"))
    #expect(!last.canReprocess(focused: "slack", value: nil))
    #expect(!LastInsert(target: "slack", text: "hello").canReprocess(focused: "slack", value: "Hi hello"))
    var unread = raw()
    unread.fieldValue = nil  // a field whose text can't be read can't be checked, so no offer
    #expect(!LastInsert(target: "slack", text: "hello", reprocess: unread).canReprocess(focused: "slack", value: nil))
}

@Test func rawFallbackWhileLoadingIsMarkedDegraded() async {
    let p = Pipeline(complete: { _, _, _, _ in throw Pipeline.ModelLoading() },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "a", editModel: "b")
    #expect(await p.run(Request(transcript: "hello", selection: nil, context: ScreenSnapshot())).degraded)
    let ok = Pipeline(complete: { _, _, _, _ in "Hello." },
                      vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                      cleanupModel: "a", editModel: "b")
    #expect(await !ok.run(Request(transcript: "hello", selection: nil, context: ScreenSnapshot())).degraded)
}
