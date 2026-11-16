import Testing
@testable import ChatCore

struct ThinkTagSplitterTests {
    private func run(_ chunks: [String]) -> (content: String, reasoning: String) {
        var splitter = ThinkTagSplitter()
        var events = chunks.flatMap { splitter.push($0) }
        events += splitter.flush()
        var content = "", reasoning = ""
        for event in events {
            switch event {
            case .content(let t): content += t
            case .reasoning(let t): reasoning += t
            default: break
            }
        }
        return (content, reasoning)
    }

    @Test(arguments: [
        ("<think>plan <b>it</b></think>Answer <i>here</i>", "Answer <i>here</i>", "plan <b>it</b>"),
        ("no tags at all", "no tags at all", ""),
        ("a<think>b</think>c<think>d</think>e", "ace", "bd"),
        ("1 < 2 and <thin", "1 < 2 and <thin", ""),
        ("<think>unterminated </thi", "", "unterminated </thi"),
        ("<think>plan</think>\n\nOkay.", "Okay.", "plan"),
        ("\n\n  Okay.\n", "Okay.\n", ""),
        ("a<think>b</think>\n\nc", "a\n\nc", "b"),
    ])
    func splitsAtEveryBoundary(input: String, content: String, reasoning: String) {
        let chars = Array(input)
        for cut in 0...chars.count {
            let result = run([String(chars[..<cut]), String(chars[cut...])])
            #expect(result.content == content, "cut \(cut)")
            #expect(result.reasoning == reasoning, "cut \(cut)")
        }
    }

    @Test func oneCharacterAtATime() {
        let result = run("<think>abc</think>def".map(String.init))
        #expect(result.content == "def")
        #expect(result.reasoning == "abc")
    }
}
