import Foundation
import Testing

@testable import Whalebridge

@Suite struct ContainerSummaryTests {
    @Test func decodesDockerContainerJSON() throws {
        let json = """
            [{"Id": "abc123def4567890", "Names": ["/wb-running"],
              "Image": "nginx:latest", "State": "running", "Status": "Up 2 hours"}]
            """
        let containers = try JSONDecoder().decode([ContainerSummary].self, from: Data(json.utf8))
        let container = try #require(containers.first)
        #expect(container.id == "abc123def4567890")
        #expect(container.name == "wb-running")
        #expect(container.image == "nginx:latest")
        #expect(container.isRunning)
    }

    @Test func stoppedContainerIsNotRunning() throws {
        let json = """
            [{"Id": "abc", "Names": ["/wb-stopped"], "Image": "alpine",
              "State": "exited", "Status": "Exited (0) 5 minutes ago"}]
            """
        let containers = try JSONDecoder().decode([ContainerSummary].self, from: Data(json.utf8))
        #expect(containers.first?.isRunning == false)
    }

    @Test func nameFallsBackToIDPrefixWhenNamesEmpty() throws {
        let json = """
            [{"Id": "0123456789abcdef0123", "Names": [], "Image": "alpine",
              "State": "exited", "Status": ""}]
            """
        let containers = try JSONDecoder().decode([ContainerSummary].self, from: Data(json.utf8))
        #expect(containers.first?.name == "0123456789ab")
    }
}

@Suite struct DechunkTests {
    private func dechunk(_ string: String) -> String {
        let data = Data(string.utf8)
        return String(decoding: UnixHTTP.dechunk(data[...]), as: UTF8.self)
    }

    @Test func reassemblesChunks() {
        #expect(dechunk("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n") == "hello world")
    }

    @Test func ignoresChunkExtensions() {
        #expect(dechunk("5;ext=1\r\nhello\r\n0\r\n\r\n") == "hello")
    }

    @Test func stopsAtTruncatedChunk() {
        // A chunk header promising more bytes than remain must not crash.
        #expect(dechunk("ff\r\nshort\r\n") == "")
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(dechunk("") == "")
    }
}
