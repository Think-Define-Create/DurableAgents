import DurableCore
import DurableMCP
import Foundation
import MCP

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum MCPListenSupport {
    public static var available: Bool {
        #if os(macOS) || os(Linux)
        true
        #else
        false
        #endif
    }
}

/// Loopback HTTP in front of `DurableMCPServer.handleHTTP`. macOS and Linux only.
public final class MCPLoopbackServer: @unchecked Sendable {
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(_ handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.handler = handler
    }

    public func start() throws -> Int {
        #if os(macOS) || os(Linux)
        #if canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        #if canImport(Glibc) || canImport(Musl)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw AgentError.invalidURL }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            closeSocket(fd)
            throw AgentError.mcpListenUnavailable
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                getsockname(fd, sock, &length)
            }
        }
        guard named == 0 else {
            closeSocket(fd)
            throw AgentError.mcpListenUnavailable
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        Thread { [weak self] in
            self?.serve()
        }.start()
        return port
        #else
        throw AgentError.mcpListenUnavailable
        #endif
    }

    public func stop() {
        #if os(macOS) || os(Linux)
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            closeSocket(fd)
        }
        #endif
    }

    #if os(macOS) || os(Linux)
    private func serve() {
        while true {
            lock.lock()
            let keep = running
            let fd = listenFD
            lock.unlock()
            if !keep || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            guard let raw = readRequest(client) else {
                closeSocket(client)
                continue
            }
            let http = parse(raw)
            let box = ResponseBox()
            let semaphore = DispatchSemaphore(value: 0)
            let handler = self.handler
            Task {
                box.response = await handler(http)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
            let payload = box.response.map(wire) ?? Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = payload.withUnsafeBytes { pointer in
                send(client, pointer.baseAddress, pointer.count, sendFlags)
            }
            closeSocket(client)
        }
    }

    private func parse(_ raw: String) -> HTTPRequest {
        let lines = httpLines(raw)
        let head = lines.first ?? "POST /mcp HTTP/1.1"
        let method = head.split(separator: " ").first.map(String.init) ?? "POST"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<split])
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let body = httpBody(raw).data(using: .utf8)
        return HTTPRequest(method: method, headers: headers, body: body, path: "/mcp")
    }

    private func wire(_ response: HTTPResponse) -> Data {
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        var text = "HTTP/1.1 \(response.statusCode) OK\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private func readRequest(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let marker = Array("\r\n\r\n".utf8)
        while data.count < 1_000_000 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base, raw.count, 0)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if let end = indexAfterMarker(data, marker: marker) {
                let header = String(decoding: data[..<(data.startIndex + (end - marker.count))], as: UTF8.self)
                let length = contentLength(header)
                if data.count >= end + length {
                    return String(decoding: data.prefix(end + length), as: UTF8.self)
                }
            }
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    private func indexAfterMarker(_ data: Data, marker: [UInt8]) -> Int? {
        guard data.count >= marker.count else { return nil }
        let bytes = Array(data)
        var index = 0
        while index + marker.count <= bytes.count {
            if Array(bytes[index..<(index + marker.count)]) == marker {
                return index + marker.count
            }
            index += 1
        }
        return nil
    }

    private func contentLength(_ header: String) -> Int {
        for line in httpLines(header) {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func httpLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if !current.isEmpty { lines.append(current) }
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func httpBody(_ raw: String) -> String {
        let marker = "\r\n\r\n"
        guard let range = raw.range(of: marker) else { return "" }
        return String(raw[range.upperBound...])
    }

    private var sendFlags: Int32 {
        #if canImport(Glibc) || canImport(Musl)
        Int32(MSG_NOSIGNAL)
        #else
        0
        #endif
    }

    private func closeSocket(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #elseif canImport(Musl)
        _ = Musl.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }
    #endif
}

private final class ResponseBox: @unchecked Sendable {
    var response: HTTPResponse?
}
