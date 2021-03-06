/*
 This source file is part of the Swift.org open source project

 Copyright 2015 - 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import POSIX
import libc

public enum FileSystemError: Swift.Error {
    /// Access to the path is denied.
    ///
    /// This is used when an operation cannot be completed because a component of
    /// the path cannot be accessed.
    ///
    /// Used in situations that correspond to the POSIX EACCES error code.
    case invalidAccess
    
    /// Invalid encoding
    ///
    /// This is used when an operation cannot be completed because a path could
    /// not be decoded correctly.
    case invalidEncoding
    
    /// IO Errork encoding
    ///
    /// This is used when an operation cannot be completed due to an otherwise
    /// unspecified IO error.
    case ioError
    
    /// Is a directory
    ///
    /// This is used when an operation cannot be completed because a component
    /// of the path which was expected to be a file was not.
    ///
    /// Used in situations that correspond to the POSIX EISDIR error code.
    case isDirectory
    
    /// No such path exists.
    ///
    /// This is used when a path specified does not exist, but it was expected
    /// to.
    ///
    /// Used in situations that correspond to the POSIX ENOENT error code.
    case noEntry
    
    /// Not a directory
    ///
    /// This is used when an operation cannot be completed because a component
    /// of the path which was expected to be a directory was not.
    ///
    /// Used in situations that correspond to the POSIX ENOTDIR error code.
    case notDirectory

    /// An unspecific operating system error.
    case unknownOSError
}

private extension FileSystemError {
    init(errno: Int32) {
        switch errno {
        case libc.EACCES:
            self = .invalidAccess
        case libc.EISDIR:
            self = .isDirectory
        case libc.ENOENT:
            self = .noEntry
        case libc.ENOTDIR:
            self = .notDirectory
        default:
            self = .unknownOSError
        }
    }
}

/// Abstracted access to file system operations.
///
/// This protocol is used to allow most of the codebase to interact with a
/// natural filesystem interface, while still allowing clients to transparently
/// substitute a virtual file system or redirect file system operations.
///
/// NOTE: All of these APIs are synchronous and can block.
//
// FIXME: Design an asynchronous story?
public protocol FileSystem {
    /// Check whether the given path exists and is accessible.
    func exists(_ path: AbsolutePath) -> Bool
    
    /// Check whether the given path is accessible and a directory.
    func isDirectory(_ path: AbsolutePath) -> Bool
    
    /// Get the contents of the given directory, in an undefined order.
    //
    // FIXME: Actual file system interfaces will allow more efficient access to
    // more data than just the name here.
    func getDirectoryContents(_ path: AbsolutePath) throws -> [String]
    
    /// Create the given directory.
    mutating func createDirectory(_ path: AbsolutePath) throws

    /// Create the given directory.
    ///
    /// - recursive: If true, create missing parent directories if possible.
    mutating func createDirectory(_ path: AbsolutePath, recursive: Bool) throws

    /// Get the contents of a file.
    ///
    /// - Returns: The file contents as bytes, or nil if missing.
    //
    // FIXME: This is obviously not a very efficient or flexible API.
    func readFileContents(_ path: AbsolutePath) throws -> ByteString
    
    /// Write the contents of a file.
    //
    // FIXME: This is obviously not a very efficient or flexible API.
    mutating func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws
}

/// Convenience implementations (default arguments aren't permitted in protocol
/// methods).
public extension FileSystem {
    /// Default implementation of createDirectory(_:)
    mutating func createDirectory(_ path: AbsolutePath) throws {
        try createDirectory(path, recursive: false)
    }
}

/// Concrete FileSystem implementation which communicates with the local file system.
private class LocalFileSystem: FileSystem {
    func exists(_ path: AbsolutePath) -> Bool {
        return (try? stat(path.asString)) != nil
    }
    
    func isDirectory(_ path: AbsolutePath) -> Bool {
        guard let status = try? stat(path.asString) else {
            return false
        }
        // FIXME: We should probably have wrappers or something for this, so it
        // all comes from the POSIX module.
        return (status.st_mode & libc.S_IFDIR) != 0
    }
    
    func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        guard let dir = libc.opendir(path.asString) else {
            throw FileSystemError(errno: errno)
        }
        defer { _ = libc.closedir(dir) }
        
        var result: [String] = []
        var entry = dirent()
        
        while true {
            var entryPtr: UnsafeMutablePointer<dirent>? = nil
            if readdir_r(dir, &entry, &entryPtr) < 0 {
                // FIXME: Are there ever situation where we would want to
                // continue here?
                throw FileSystemError(errno: errno)
            }
            
            // If the entry pointer is null, we reached the end of the directory.
            if entryPtr == nil {
                break
            }
            
            // Otherwise, the entry pointer should point at the storage we provided.
            assert(entryPtr == &entry)
            
            // Add the entry to the result.
            guard let name = entry.name else {
                throw FileSystemError.invalidEncoding
            }
            
            // Ignore the pseudo-entries.
            if name == "." || name == ".." {
                continue
            }

            result.append(name)
        }
        
        return result
    }

    func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        // Try to create the directory.
        let result = mkdir(path.asString, libc.S_IRWXU | libc.S_IRWXG)

        // If it succeeded, we are done.
        if result == 0 { return }

        // If the failure was because the directory exists, everything is ok.
        if errno == EEXIST && isDirectory(path) { return }

        // If it failed due to ENOENT (e.g., a missing parent), and we are
        // recursive, then attempt to create the parent and retry.
        if errno == ENOENT && recursive &&
           path != path.parentDirectory /* FIXME: Need Path.isRoot */ {
            // Attempt to create the parent.
            try createDirectory(path.parentDirectory, recursive: true)

            // Re-attempt creation, non-recursively.
            try createDirectory(path, recursive: false)
        } else {
            // Otherwise, we failed due to some other error. Report it.
            throw FileSystemError(errno: errno)
        }
    }
    
    func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        // Open the file.
        let fp = fopen(path.asString, "rb")
        if fp == nil {
            throw FileSystemError(errno: errno)
        }
        defer { fclose(fp) }

        // Read the data one block at a time.
        let data = OutputByteStream()
        var tmpBuffer = [UInt8](repeating: 0, count: 1 << 12)
        while true {
            let n = fread(&tmpBuffer, 1, tmpBuffer.count, fp)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileSystemError.ioError
            }
            if n == 0 {
                if ferror(fp) != 0 {
                    throw FileSystemError.ioError
                }
                break
            }
            data <<< tmpBuffer[0..<n]
        }
        
        return data.bytes
    }
    
    func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        // Open the file.
        let fp = fopen(path.asString, "wb")
        if fp == nil {
            throw FileSystemError(errno: errno)
        }
        defer { fclose(fp) }

        // Write the data in one chunk.
        var contents = bytes.contents
        while true {
            let n = fwrite(&contents, 1, contents.count, fp)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileSystemError.ioError
            }
            if n != contents.count {
                throw FileSystemError.ioError
            }
            break
        }
    }
}

/// Concrete FileSystem implementation which simulates an empty disk.
//
// FIXME: This class does not yet support concurrent mutation safely.
public class InMemoryFileSystem: FileSystem {
    private class Node {
        /// The actual node data.
        let contents: NodeContents
        
        init(_ contents: NodeContents) {
            self.contents = contents
        }
    }
    private enum NodeContents {
        case file(ByteString)
        case directory(DirectoryContents)
    }    
    private class DirectoryContents {
        var entries:  [String: Node]

        init(entries: [String: Node] = [:]) {
            self.entries = entries
        }
    }
    
    /// The root filesytem.
    private var root: Node

    public init() {
        root = Node(.directory(DirectoryContents()))
    }

    /// Get the node corresponding to get given path.
    private func getNode(_ path: AbsolutePath) throws -> Node? {
        func getNodeInternal(_ path: AbsolutePath) throws -> Node? {
            // If this is the root node, return it.
            if path.isRoot {
                return root
            }

            // Otherwise, get the parent node.
            guard let parent = try getNodeInternal(path.parentDirectory) else {
                return nil
            }

            // If we didn't find a directory, this is an error.
            guard case .directory(let contents) = parent.contents else {
                throw FileSystemError.notDirectory
            }

            // Return the directory entry.
            return contents.entries[path.basename]
        }

        // Get the node that corresponds to the path.
        return try getNodeInternal(path)
    }

    // MARK: FileSystem Implementation
    
    public func exists(_ path: AbsolutePath) -> Bool {
        do {
            return try getNode(path) != nil
        } catch {
            return false
        }
    }
    
    public func isDirectory(_ path: AbsolutePath) -> Bool {
        do {
            if case .directory? = try getNode(path)?.contents {
                return true
            }
            return false
        } catch {
            return false
        }
    }
    
    public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        guard let node = try getNode(path) else {
            throw FileSystemError.noEntry
        }
        guard case .directory(let contents) = node.contents else {
            throw FileSystemError.notDirectory
        }

        // FIXME: Perhaps we should change the protocol to allow lazy behavior.
        return [String](contents.entries.keys)
    }

    public func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        // Get the parent directory node.
        let parentPath = path.parentDirectory
        guard let parent = try getNode(parentPath) else {
            // If the parent doesn't exist, and we are recursive, then attempt
            // to create the parent and retry.
            if recursive && path != parentPath {
                // Attempt to create the parent.
                try createDirectory(parentPath, recursive: true)

                // Re-attempt creation, non-recursively.
                return try createDirectory(path, recursive: false)
            } else {
                // Otherwise, we failed.
                throw FileSystemError.noEntry
            }
        }

        // Check that the parent is a directory.
        guard case .directory(let contents) = parent.contents else {
            // The parent isn't a directory, this is an error.
            throw FileSystemError.notDirectory
        }
        
        // Check if the node already exists.
        if let node = contents.entries[path.basename] {
            // Verify it is a directory.
            guard case .directory = node.contents else {
                // The path itself isn't a directory, this is an error.
                throw FileSystemError.notDirectory
            }

            // We are done.
            return
        }

        // Otherwise, the node does not exist, create it.
        contents.entries[path.basename] = Node(.directory(DirectoryContents()))
    }

    public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        // Get the node.
        guard let node = try getNode(path) else {
            throw FileSystemError.noEntry
        }

        // Check that the node is a file.
        guard case .file(let contents) = node.contents else {
            // The path is a directory, this is an error.
            throw FileSystemError.isDirectory
        }

        // Return the file contents.
        return contents
    }

    public func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        // It is an error if this is the root node.
        let parentPath = path.parentDirectory
        guard path != parentPath else {
            throw FileSystemError.isDirectory
        }
            
        // Get the parent node.
        guard let parent = try getNode(parentPath) else {
            throw FileSystemError.noEntry
        }

        // Check that the parent is a directory.
        guard case .directory(let contents) = parent.contents else {
            // The parent isn't a directory, this is an error.
            throw FileSystemError.notDirectory
        }

        // Check if the node exists.
        if let node = contents.entries[path.basename] {
            // Verify it is a file.
            guard case .file = node.contents else {
                // The path is a directory, this is an error.
                throw FileSystemError.isDirectory
            }
        }

        // Write the file.
        contents.entries[path.basename] = Node(.file(bytes))
    }
}

/// A rerooted view on an existing FileSystem.
///
/// This is a simple wrapper which creates a new FileSystem view into a subtree
/// of an existing filesystem. This is useful for passing to clients which only
/// need access to a subtree of the filesystem but should otherwise remain
/// oblivious to its concrete location.
///
/// NOTE: The rerooting done here is purely at the API level and does not
/// inherently prevent access outside the rerooted path (e.g., via symlinks). It
/// is designed for situations where a client is only interested in the contents
/// *visible* within a subpath and is agnostic to the actual location of those
/// contents.
public struct RerootedFileSystemView: FileSystem {
    /// The underlying file system.
    private var underlyingFileSystem: FileSystem

    /// The root path within the containing file system.
    private let root: AbsolutePath
    
    public init(_ underlyingFileSystem: inout FileSystem, rootedAt root: AbsolutePath) {
        self.underlyingFileSystem = underlyingFileSystem
        self.root = root
    }

    /// Adjust the input path for the underlying file system.
    private func formUnderlyingPath(_ path: AbsolutePath) -> AbsolutePath {
        if path == AbsolutePath.root {
            return root
        } else {
            // FIXME: Optimize?
            return root.appending(RelativePath(String(path.asString.characters.dropFirst(1))))
        }
    }
    
    // MARK: FileSystem Implementation

    public func exists(_ path: AbsolutePath) -> Bool {
        return underlyingFileSystem.exists(formUnderlyingPath(path))
    }
    
    public func isDirectory(_ path: AbsolutePath) -> Bool {
        return underlyingFileSystem.isDirectory(formUnderlyingPath(path))
    }
    
    public func getDirectoryContents(_ path: AbsolutePath) throws -> [String] {
        return try underlyingFileSystem.getDirectoryContents(formUnderlyingPath(path))
    }

    public mutating func createDirectory(_ path: AbsolutePath, recursive: Bool) throws {
        return try underlyingFileSystem.createDirectory(formUnderlyingPath(path), recursive: recursive)
    }

    public func readFileContents(_ path: AbsolutePath) throws -> ByteString {
        return try underlyingFileSystem.readFileContents(formUnderlyingPath(path))
    }

    public mutating func writeFileContents(_ path: AbsolutePath, bytes: ByteString) throws {
        return try underlyingFileSystem.writeFileContents(formUnderlyingPath(path), bytes: bytes)
    }
}

/// Public access to the local FS proxy.
public var localFileSystem: FileSystem = LocalFileSystem()
