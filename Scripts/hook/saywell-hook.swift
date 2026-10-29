// saywell-hook: Claude Code runs this on its hook events (C6). It passes the
// event to Saywell over a local Unix socket and, for a permission request
// (or `--ask`, an AskUserQuestion), waits for the answer picked in the notch
// and prints it. If Saywell isn't running or nobody answers, it prints
// nothing, so Claude Code asks in the terminal as usual. Always exits 0.
// Built by Scripts/make_app.sh into Saywell.app/Contents/Helpers.
import Foundation

let ask = CommandLine.arguments.contains("--ask")
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
let event = payload["hook_event_name"] as? String ?? ""
let kind = ask ? "ask" : (event == "PermissionRequest" ? "permission" : "event")
var env: [String: String] = [:]
for key in ["TERM_PROGRAM", "__CFBundleIdentifier", "PWD"] { env[key] = ProcessInfo.processInfo.environment[key] }
guard var message = try? JSONSerialization.data(withJSONObject: ["kind": kind, "payload": payload, "env": env]) else { exit(0) }
message.append(0x0A)

let path = NSHomeDirectory() + "/Library/Application Support/Saywell/agent.sock"
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: address.sun_path)
guard path.utf8.count < capacity else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { exit(0) }   // Saywell isn't running

var sent = 0
message.withUnsafeBytes { bytes in
    while sent < bytes.count {
        let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
        if n <= 0 { break }
        sent += n
    }
}
guard kind != "event" else { close(fd); exit(0) }

// Wait for the answer, a little less than Claude Code's hook timeout.
var timeout = timeval(tv_sec: ask ? 125 : 118, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var reply = Data()
var buffer = [UInt8](repeating: 0, count: 65_536)
while !reply.contains(0x0A) {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    reply.append(buffer, count: n)
}
close(fd)
if let line = reply.split(separator: 0x0A).first,
   let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
   let output = json["output"] as? String {
    FileHandle.standardOutput.write(Data((output + "\n").utf8))
}
exit(0)
