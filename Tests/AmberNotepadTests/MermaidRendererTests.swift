import AppKit
import CryptoKit
import XCTest
@testable import AmberNotepad

final class MermaidRendererTests: XCTestCase {
    static let flowchart = "graph TD\n  A[Start] --> B[End]"

    func test_vendored_mermaid_file_matches_its_pinned_sha256() throws {
        let file = MermaidPage.resourceDirectory().appendingPathComponent(MermaidPage.scriptName)
        let digest = SHA256.hash(data: try Data(contentsOf: file))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest, "336df803d87a38b70a01e736e666c8f7601d2ce42f5e47c8fafe5d721074b9a3"
        )
    }

    func test_page_html_blocks_the_network_and_runs_mermaid_strictly() {
        XCTAssertTrue(MermaidPage.html.contains(
            "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
            + "script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:\">"
        ))
        XCTAssertTrue(MermaidPage.html.contains("securityLevel: 'strict'"))
        XCTAssertTrue(MermaidPage.html.contains("theme: 'base'"))
    }

    func test_the_loaded_page_reports_a_policy_violation_for_a_network_request() async throws {
        let renderer = await MainActor.run { MermaidRenderer() }
        let blocked = await renderer.probe("""
            return await new Promise(resolve => {
                document.addEventListener('securitypolicyviolation', () => resolve('blocked'));
                fetch('http://127.0.0.1:9/probe').then(() => resolve('reached'),
                    () => setTimeout(() => resolve('failed without a violation'), 2000));
            })
            """)
        XCTAssertEqual(blocked as? String, "blocked")
    }

    func test_a_flowchart_becomes_a_non_empty_image() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        let outcome = await renderer.render(Self.flowchart)
        guard case .image(let image) = outcome else {
            return XCTFail("expected an image, got \(outcome)")
        }
        XCTAssertGreaterThan(image.size.width, 50)
        XCTAssertGreaterThan(image.size.height, 50)
        XCTAssertTrue(image.representations.first is NSPDFImageRep)
    }

    func test_a_syntax_error_yields_mermaids_message() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        let outcome = await renderer.render("graph TD\n  A --> --> B")
        guard case .failure(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("Parse error on line 2"), message)
    }

    func test_rendering_the_same_source_twice_draws_once_and_returns_the_same_image() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        let first = await renderer.render(Self.flowchart)
        let start = Date()
        let second = await renderer.render(Self.flowchart)
        let cachedSeconds = Date().timeIntervalSince(start)
        guard case .image(let a) = first, case .image(let b) = second else {
            return XCTFail("expected images")
        }
        XCTAssertTrue(a === b)
        let draws = await renderer.drawCount
        XCTAssertEqual(draws, 1)
        XCTAssertLessThan(cachedSeconds, 0.05)
    }

    func test_concurrent_renders_of_one_source_draw_once() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        async let first = renderer.render(Self.flowchart)
        async let second = renderer.render(Self.flowchart)
        _ = await (first, second)
        let draws = await renderer.drawCount
        XCTAssertEqual(draws, 1)
    }

    @MainActor func test_a_diagram_wider_than_the_line_is_scaled_down_never_up() {
        let wide = DiagramAttachment(image: NSImage(size: NSSize(width: 400, height: 200)))
        let line = NSRect(x: 0, y: 0, width: 200, height: 20)
        XCTAssertEqual(
            wide.attachmentBounds(
                for: nil, proposedLineFragment: line, glyphPosition: .zero, characterIndex: 0
            ).size, NSSize(width: 200, height: 100)
        )
        let roomy = NSRect(x: 0, y: 0, width: 900, height: 20)
        XCTAssertEqual(
            wide.attachmentBounds(
                for: nil, proposedLineFragment: roomy, glyphPosition: .zero, characterIndex: 0
            ).size, NSSize(width: 400, height: 200)
        )
    }
}

final class MermaidRobustnessTests: XCTestCase {
    private static let hangsOnHang = """
        if (source.includes('HANG')) {
            return await new Promise(resolve => setTimeout(resolve, 600000));
        }
        return await amberRender(id, source)
        """

    func test_a_draw_that_never_finishes_times_out_without_blocking_the_next_diagram() async {
        let renderer = await MainActor.run {
            MermaidRenderer(timeout: 0.5, drawScript: Self.hangsOnHang)
        }
        let start = Date()
        let stuck = await renderer.render("graph TD\n  HANG --> B")
        let waited = Date().timeIntervalSince(start)
        guard case .failure(let message) = stuck else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "Diagram took too long to render")
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        XCTAssertLessThan(waited, 3)

        let next = await renderer.render(MermaidRendererTests.flowchart)
        guard case .image = next else { return XCTFail("the next diagram must still render") }
    }

    func test_a_timed_out_diagram_is_not_cached() async {
        let renderer = await MainActor.run {
            MermaidRenderer(timeout: 0.3, drawScript: Self.hangsOnHang)
        }
        _ = await renderer.render("graph TD\n  HANG --> B")
        let cached = await renderer.cachedOutcome(for: "graph TD\n  HANG --> B")
        XCTAssertNil(cached)
    }

    func test_diagram_source_is_data_never_script() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        let source = "graph TD\n  %% \"double\" 'single' `tick` \\ ${1+1} </script>\n"
            + "  A[\"x </script><script>window.pwned=1</script> ${1+1}\"] --> B"
        let outcome = await renderer.render(source)
        guard case .image = outcome else { return XCTFail("expected an image, got \(outcome)") }
        let pwned = await renderer.probe("return String(window.pwned)")
        XCTAssertEqual(pwned as? String, "undefined")
        let again = await renderer.render(MermaidRendererTests.flowchart)
        guard case .image = again else { return XCTFail("the page must still work") }
    }

    func test_a_transient_failure_is_not_cached_and_is_retried_on_the_next_render() async {
        let renderer = await MainActor.run {
            MermaidRenderer(drawScript: "if (source.includes('SILENT')) { return null; }")
        }
        let source = "graph TD\n  SILENT --> B"
        let first = await renderer.render(source)
        guard case .failure(let message) = first else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "Mermaid did not respond")
        let cached = await renderer.cachedOutcome(for: source)
        XCTAssertNil(cached)
        _ = await renderer.render(source)
        let draws = await renderer.drawCount
        XCTAssertEqual(draws, 2)
    }

    func test_the_page_cancels_every_navigation_after_its_own_load() async {
        let renderer = await MainActor.run { MermaidRenderer() }
        _ = await renderer.probe(
            "setTimeout(() => { location.href = 'about:blank'; }, 0); return 1"
        )
        try? await Task.sleep(nanoseconds: 400_000_000)
        let kind = await renderer.probe("return typeof amberRender")
        XCTAssertEqual(kind as? String, "function")
    }
}
