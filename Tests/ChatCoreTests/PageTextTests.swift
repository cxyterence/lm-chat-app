import Testing
@testable import ChatCore

struct PageTextTests {
    @Test func scriptsStylesNoscriptCommentsAndTagsAreDropped() {
        let page = PageText.extract(fromHTML: """
            <!doctype html><html><head><meta charset="utf-8"><title>Example Domain</title>
            <style>body { color: red }</style><script>var hidden = "<p>no</p>";</script></head>
            <body><!-- a <b>comment</b> --><noscript>Turn on JavaScript</noscript>
            <p>Hello <a href="/x?a=1&b=2" title="a > b">world</a>.</p><script type="x">alert(1)</script>
            </body></html>
            """)
        #expect(page.title == "Example Domain")
        #expect(page.text == "Hello world.")
    }

    @Test func headContentExceptTheTitleIsDroppedEvenWhenItIsNeverClosed() {
        let page = PageText.extract(fromHTML: "<head><title>Docs</title><meta name=d content='x'>stray text<body><h1>Intro</h1>")
        #expect(page.title == "Docs")
        #expect(page.text == "Intro")
    }

    @Test func namedAndNumericEntitiesAreDecodedAndUnknownOnesLeftAlone() {
        let page = PageText.extract(fromHTML: "<title>Fish &amp; Chips &#8211; Menu</title><p>&lt;b&gt; &quot;hi&quot; &#x41;&#66; &copy; 2026&nbsp;ok &bogus; AT&T &#xZZ;</p>")
        #expect(page.title == "Fish & Chips – Menu")
        #expect(page.text == "<b> \"hi\" AB © 2026 ok &bogus; AT&T &#xZZ;")
    }

    @Test func blockEndsAndBreaksBecomeLineBreaksAndBlankRunsCollapse() {
        let page = PageText.extract(fromHTML: """
            <h1>Title</h1>



            <p>One<br>two<br/>three</p><div><div></div></div><ul><li>a</li><li>b</li></ul>   <p>   spaced    out   </p>
            """)
        #expect(page.text == "Title\n\nOne\ntwo\nthree\n\na\nb\n\nspaced out")
    }

    @Test func textInsideAPreKeepsItsSpacesAndLines() {
        let page = PageText.extract(fromHTML: "<p>Run:</p><pre>  swift build\n    --verbose</pre><p>done</p>")
        #expect(page.text == "Run:\n\n  swift build\n    --verbose\n\ndone")
    }

    @Test func aBareLessThanIsTextAndAnUnclosedTagEndsThePage() {
        #expect(PageText.extract(fromHTML: "<p>if a < b and 3 <5 then</p>").text == "if a < b and 3 <5 then")
        #expect(PageText.extract(fromHTML: "<p>kept</p><p class=\"never closed").text == "kept")
    }

    @Test func aPageWithNoTitleHasNone() {
        #expect(PageText.extract(fromHTML: "<p>x</p>").title == nil)
        #expect(PageText.extract(fromHTML: "<title>  </title><p>x</p>").title == nil)
    }
}
