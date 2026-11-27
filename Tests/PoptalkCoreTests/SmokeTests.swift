import Foundation
import Testing
@testable import PoptalkCore

// #149: the rescorer ignored `weight`, so it's gone; files that still have it load.
@Test func vocabTermIgnoresAWeightInOldFiles() throws {
    let t = try JSONDecoder().decode(VocabTerm.self, from: Data(#"{"text":"Todoist","aliases":["todo list"],"weight":7}"#.utf8))
    #expect(t == VocabTerm(text: "Todoist", aliases: ["todo list"]))
    #expect(!String(decoding: try JSONEncoder().encode(t), as: UTF8.self).contains("weight"))
}
