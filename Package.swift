// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmberNotepad",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AmberNotepad", targets: ["AmberNotepad"])],
    targets: [
        .target(name: "NotepadCore"),
        .executableTarget(name: "AmberNotepad", dependencies: ["NotepadCore"]),
        .testTarget(name: "NotepadCoreTests", dependencies: ["NotepadCore"]),
        .testTarget(name: "AmberNotepadTests", dependencies: ["AmberNotepad"])
    ]
)
