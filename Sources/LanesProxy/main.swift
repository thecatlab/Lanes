import Darwin
import Foundation
import LanesProxyKit

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}
let directory = argument("--state-directory").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ProxySettings.directory
let port = argument("--port").flatMap(UInt16.init) ?? ProxySettings.port
let server = ProxyServer(directory: directory, port: port)
server.onReady = { print("LanesProxy ready on 127.0.0.1:\(port)"); fflush(stdout) }
server.onFailure = { error in fputs("LanesProxy: \(error.localizedDescription)\n", stderr); exit(1) }
signal(SIGPIPE, SIG_IGN)
do { try server.start(); dispatchMain() }
catch { fputs("LanesProxy: \(error.localizedDescription)\n", stderr); exit(1) }
