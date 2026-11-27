import Foundation

/// The invisible page Mermaid draws in, and where its bundled script lives on disk.
enum MermaidPage {
    static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        + "img-src data:"

    static let scriptName = "mermaid.min.js"

    /// Colors from `Phosphor`: amber lines and text on darker amber fills.
    static let themeVariables = """
        {"background":"transparent","fontFamily":"Menlo, monospace",\
        "primaryColor":"#3A2305","primaryTextColor":"#FFB038","primaryBorderColor":"#FFB038",\
        "secondaryColor":"#2A1904","secondaryTextColor":"#FFB038",\
        "secondaryBorderColor":"#CC8D2D","tertiaryColor":"#1E1204",\
        "tertiaryTextColor":"#FFB038","tertiaryBorderColor":"#CC8D2D","lineColor":"#FFB038",\
        "textColor":"#FFB038","noteBkgColor":"#3A2305","noteTextColor":"#FFBF4A",\
        "noteBorderColor":"#CC8D2D","edgeLabelBackground":"#110A03","clusterBkg":"#1E1204",\
        "clusterBorder":"#CC8D2D","titleColor":"#FFBF4A","actorBkg":"#3A2305",\
        "actorBorder":"#FFB038","actorTextColor":"#FFB038","actorLineColor":"#CC8D2D",\
        "signalColor":"#FFB038","signalTextColor":"#FFB038","labelBoxBkgColor":"#3A2305",\
        "labelBoxBorderColor":"#FFB038","labelTextColor":"#FFB038","loopTextColor":"#FFB038"}
        """

    static let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <script>
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: 'base',
            suppressErrorRendering: true, themeVariables: \(themeVariables)});
        async function amberRender(id, source) {
            try {
                const result = await mermaid.render(id, source);
                const out = document.getElementById('out');
                out.innerHTML = result.svg;
                const svg = out.querySelector('svg');
                const box = svg.viewBox.baseVal;
                const size = box && box.width > 0
                    ? {width: box.width, height: box.height}
                    : svg.getBoundingClientRect();
                svg.style.maxWidth = 'none';
                svg.setAttribute('width', size.width);
                svg.setAttribute('height', size.height);
                return {ok: true, width: size.width, height: size.height};
            } catch (error) {
                return {ok: false, message: String((error && error.message) || error)};
            }
        }
        </script></head>
        <body style="margin:0;background:transparent"><div id="out"></div></body></html>
        """

    /// The app's own `Contents/Resources/Mermaid`, which `scripts/build-app.sh` fills, or the
    /// package's resource bundle when running from the build folder or in tests.
    static func resourceDirectory() -> URL {
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("Mermaid"),
           FileManager.default.fileExists(atPath: folder.appendingPathComponent(scriptName).path) {
            return folder
        }
        return Bundle.module.resourceURL!.appendingPathComponent("Mermaid")
    }
}
