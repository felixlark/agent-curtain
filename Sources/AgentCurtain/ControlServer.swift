import AgentCurtainCore
import Darwin
import Foundation

final class ControlServer {
    typealias Handler = (ControlCommand, @escaping (ControlResponse) -> Void) -> Void

    private let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "agent-curtain.control")
    private var listeningFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() throws {
        guard socketURL.path.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw ControlServerError.pathTooLong
        }
        unlink(socketURL.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.posix("socket", errno) }
        listeningFD = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard bindResult == 0 else {
            let error = errno
            close(fd)
            listeningFD = -1
            throw ControlServerError.posix("bind", error)
        }
        guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw ControlServerError.posix("chmod", errno)
        }
        guard listen(fd, 8) == 0 else { throw ControlServerError.posix("listen", errno) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableClients() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        listeningFD = -1
        unlink(socketURL.path)
    }

    private func acceptAvailableClients() {
        while listeningFD >= 0 {
            let client = Darwin.accept(listeningFD, nil, nil)
            if client < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        // 读行的细节(阻塞、超时、EAGAIN 不是 EOF)在 ControlLineReader 里,
        // 那里有针对 2026-09-06 竞态的回归测试。
        let line: String
        switch ControlLineReader.readLine(from: client) {
        case .success(let text):
            line = text
        case .failure(let failure):
            send(ControlResponse(ok: false, error: failure.errorDescription), to: client)
            return
        }
        do {
            let command = try ControlCommand.parse(line)
            DispatchQueue.main.async { [handler, weak self] in
                handler(command) { [weak self] response in self?.send(response, to: client) }
            }
        } catch {
            send(ControlResponse(ok: false, error: error.localizedDescription), to: client)
        }
    }

    private func send(_ response: ControlResponse, to client: Int32) {
        let data = response.jsonLine()
        data.withUnsafeBytes { bytes in
            _ = Darwin.send(client, bytes.baseAddress, bytes.count, 0)
        }
        shutdown(client, SHUT_RDWR)
        close(client)
    }
}

enum ControlServerError: Error, LocalizedError {
    case pathTooLong
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong: return "control socket path is too long"
        case .posix(let operation, let code): return "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}
