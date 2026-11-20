import Foundation
import Testing
@testable import PoptalkCore

// #59: spoken numbers → digits (inverse text normalization), house style.
private let n = Pipeline.spokenNumbers

@Test(arguments: [
    // The report.
    ("Okay to proceed with fifty two. Um and for fifty one let's strip it locally at first launch.",
     "Okay to proceed with 52. Um and for 51 let's strip it locally at first launch."),
    // Compound and large numbers.
    ("one hundred and five", "105"),
    ("two thousand twenty six", "2026"),
    ("Fifty-two cards", "52 cards"),
    ("about seventy five thousand users", "about 75,000 users"),
    ("twenty five hundred words", "2500 words"),
    ("three point five", "3.5"),
    ("pi is three point one four", "pi is 3.14"),
    // Ten and up.
    ("we have ten days", "we have 10 days"),
    ("ten or twenty", "10 or 20"),
    // Small numbers after cue words.
    ("see issue five", "see issue 5"),
    ("Version two ships", "Version 2 ships"),
    ("go to page three, step four", "go to page 3, step 4"),
    ("merge PR seven", "merge PR 7"),
    ("the Q three okrs", "the Q3 okrs"),
    ("ship v two", "ship v2"),
    ("ticket # nine", "ticket #9"),
    ("option one is best", "option 1 is best"),
    // Units.
    ("twenty five percent", "25%"),
    ("five percent of three point five percent", "5% of 3.5%"),
    ("five dollars", "$5"),
    ("it costs fifty dollars", "it costs $50"),
    // Times.
    ("three thirty pm", "3:30 PM"),
    ("nine am tomorrow", "9 AM tomorrow"),
    ("at seven oh five p.m.", "at 7:05 PM"),
    ("twelve fifteen am", "12:15 AM"),
    // Ordinals.
    ("the twenty first century", "the 21st century"),
    ("one hundred and third run", "103rd run"),
    ("thirty third floor", "33rd floor"),
    // "second" is never an ordinal: a fifty second delay is 50 seconds.
    ("a fifty second delay", "a 50 second delay"),
])
func spokenNumbersBecomeDigits(_ said: String, _ written: String) {
    #expect(n(said) == written)
}

@Test(arguments: [
    "one of my",
    "two people",
    "one or two",
    "a hundred times",
    "a hundred and fifty",
    "a thousand thanks",
    "first",
    "the second time, third time",
    "the tenth time",
    "count one two three",
    "one, two, three",
    "at nine",
    "twelve fifty",
    "twelve fifty dollars",
    "nineteen ninety nine",
    "it's already 52 and 3.5%",
    "point five",
    "zero",
    "everyone and nobody",
    "the one's mine",
])
func numbersThatStayWords(_ said: String) {
    #expect(n(said) == said)
}

private func dictate(_ transcript: String, reply: String) async -> Outcome {
    let p = Pipeline(complete: { _, _, _, _ in reply },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "s", editModel: "b")
    return await p.run(Request(transcript: transcript, selection: nil, context: ScreenSnapshot())).outcome
}

@Test func modelAndRawFallbackGetDigits() async {
    let said = "seventy five thousand twenty two items over thirty one days, ninety nine percent done"
    let digits = "75,022 items over 31 days, 99% done"
    // The drop guard (#47) compares against the normalized transcript, so words → digits isn't lost content.
    #expect(await dictate(said, reply: "75,022 items over 31 days, 99% done.") == .insert("75,022 items over 31 days, 99% done.", label: "Dictated"))
    #expect(await dictate(said, reply: "") == .insert(digits, label: "Dictated (raw)"))
}

// #66: NeMo's wins, ported.
@Test(arguments: [
    // Cents join a dollar amount; bare cents stay a unit word ("50 cents", not ¢ or $0.50).
    ("five dollars and fifty cents", "$5.50"),
    ("twelve dollars and five cents", "$12.05"),
    ("it was twenty dollars ninety nine cents", "it was $20.99"),
    ("one dollar and one cent", "$1.01"),
    ("fifty cents", "50 cents"),
    // "second" after a tens word is an ordinal, unless it's the unit of a duration.
    ("she finished twenty second", "she finished 22nd"),
    ("the twenty second floor", "the 22nd floor"),
    ("one hundred twenty second", "122nd"),
    ("the thirty second timeout", "the 30 second timeout"),
    ("wait for the forty second mark", "wait for the 40 second mark"),
    ("a twenty second wait", "a 20 second wait"),
    ("give it a twenty second head start", "give it a 20 second head start"),
    ("twenty two second delay", "22 second delay"),
    // Negatives: a sign word before a number, ASCII hyphen-minus.
    ("negative five degrees", "-5 degrees"),
    ("minus five", "-5"),
    ("it dropped to minus twelve point five", "it dropped to -12.5"),
    ("ten minus two", "10 minus two"),
    ("plus or minus fifty", "plus or minus 50"),
    ("20 minus fifteen", "20 minus 15"),
])
func nemoWins(_ said: String, _ written: String) {
    #expect(n(said) == written)
}

@Test(arguments: [
    "five cents",
    "five minus two",
    "negative feedback",
    "the second floor",
    "two second delay",
    "minus the fifth one",
])
func nemoWinsThatStayWords(_ said: String) {
    #expect(n(said) == said)
}
