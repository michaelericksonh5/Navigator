// swift-tools-version:5.9
//
// Test harness ONLY. The app is still built by ./rebuild.sh (swiftc on main.swift +
// NavigatorCore.swift) — this package exists so `swift test` can compile the pure
// path rules in NavigatorCore.swift against a test target. A single-file SwiftUI
// app can't be imported by a test bundle, so the rules worth pinning down live in
// their own file and both builds share it.
//
// Run:  ./runtests.sh      (or: swift test)

import PackageDescription

let package = Package(
    name: "NavigatorCore",
    targets: [
        .target(
            name: "NavigatorCore",
            path: ".",
            exclude: ["main.swift", "FinderExt.swift", "rebuild.sh", "runtests.sh",
                      "Tests", "Navigator.zip", "README.md"],
            sources: ["NavigatorCore.swift"]
        ),
        .testTarget(
            name: "NavigatorCoreTests",
            dependencies: ["NavigatorCore"],
            path: "Tests",
            sources: ["NavigatorCoreTests.swift"]
        ),
    ]
)
