/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import PackageDescription
import PackageGraph
import PackageModel
import Xcodeproj
import Utility
import XCTest

#if os(macOS)

class GenerateXcodeprojTests: XCTestCase {
    func testXcodebuildCanParseIt() {
        mktmpdir { dstdir in
            func dummy() throws -> [Module] {
                return [try SwiftModule(name: "DummyModuleName", sources: Sources(paths: [], root: dstdir))]
            }

            let projectName = "DummyProjectName"
            let dummyPackage = Package(manifest: Manifest(path: dstdir, url: dstdir.asString, package: PackageDescription.Package(name: "Foo"), products: [], version: nil))
            let graph = PackageGraph(rootPackage: dummyPackage, modules: try dummy(), externalModules: [], products: [])
            let outpath = try Xcodeproj.generate(dstdir: dstdir, projectName: projectName, graph: graph, options: XcodeprojOptions())

            XCTAssertDirectoryExists(outpath)
            XCTAssertEqual(outpath, dstdir.appending(component: projectName + ".xcodeproj"))

            // We can only validate this on OS X.
            // Don't allow TOOLCHAINS to be overriden here, as it breaks the test below.
            let output = try popen(["env", "-u", "TOOLCHAINS", "xcodebuild", "-list", "-project", outpath.asString]).chomp()

            let expectedOutput = "Information about project \"DummyProjectName\":\n    Targets:\n        DummyModuleName\n\n    Build Configurations:\n        Debug\n        Release\n\n    If no build configuration is specified and -scheme is not passed then \"Debug\" is used.\n\n    Schemes:\n        DummyProjectName\n".chomp()

            XCTAssertEqual(output, expectedOutput)
        }
    }
}

#endif
