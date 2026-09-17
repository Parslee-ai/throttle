import Network
import XCTest
@testable import Throttle

final class LoopbackCallbackServerTests: XCTestCase {
    private let ports: [UInt16] = [1456, 1458]

    private func requireFree(_ ports: [UInt16]) throws {
        for port in ports where !AuthTestSupport.isPortFree(port) {
            throw XCTSkip("port \(port) is in use on this machine")
        }
    }

    // MARK: Binding

    func testStartsOnFirstPreferredPortWhenFree() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        XCTAssertEqual(port, 1456)
        let bound = await server.port
        XCTAssertEqual(bound, 1456)
        await server.stop()
    }

    func testFallsBackToSecondPortWhenFirstIsHeld() async throws {
        try requireFree(ports)
        let held = try XCTUnwrap(HeldPort(1456))
        defer { held.close() }
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        XCTAssertEqual(port, 1458)
        await server.stop()
    }

    func testThrowsPortsBusyWhenEveryPortIsHeld() async throws {
        try requireFree(ports)
        let first = try XCTUnwrap(HeldPort(1456))
        let second = try XCTUnwrap(HeldPort(1458))
        defer { first.close(); second.close() }
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        do {
            _ = try await server.start()
            XCTFail("expected portsBusy")
        } catch LoopbackError.portsBusy(let busy) {
            XCTAssertEqual(busy, [1456, 1458])
        }
        await server.stop()
    }

    func testBindsIPv4LoopbackOnly() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        _ = try await server.start()
        defer { Task { await server.stop() } }
        let required = await server.requiredLocalEndpoint
        let endpoint = try XCTUnwrap(required)
        guard case .hostPort(let host, let port) = endpoint else {
            return XCTFail("expected a host/port endpoint, got \(endpoint)")
        }
        XCTAssertEqual(host, .ipv4(.loopback))
        XCTAssertEqual(port.rawValue, 1456)
        XCTAssertEqual("\(host)", "127.0.0.1")
    }

    // MARK: Callback handling

    func testParsesCodeAndStateFromRealGET() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()

        let waiter = Task { try await server.waitForCode(timeout: 5) }
        let response = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.body.contains("Signed in to Throttle. You can close this tab."))

        let callback = try await waiter.value
        XCTAssertEqual(callback, LoopbackCallback(code: "abc", state: "xyz"))

        // ISC-79: the listener is gone shortly after success.
        let released = await AuthTestSupport.eventually(timeout: 5) { AuthTestSupport.isPortFree(port) }
        XCTAssertTrue(released, "listener still bound after success")
    }

    func testOtherPathsGet400AndDoNotEndTheWait() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        let waiter = Task { try await server.waitForCode(timeout: 5) }

        let favicon = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual(favicon.status, 400)
        let noCode = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(port)/callback?foo=bar")!)
        XCTAssertEqual(noCode.status, 400)

        // Still listening: the real callback completes the wait.
        let ok = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(port)/callback?code=later")!)
        XCTAssertEqual(ok.status, 200)
        let callback = try await waiter.value
        XCTAssertEqual(callback.code, "later")
        XCTAssertNil(callback.state)
        await server.stop()
    }

    func testProviderErrorBecomesProviderDenied() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        let waiter = Task { try await server.waitForCode(timeout: 5) }

        let response = try await AuthTestSupport.get(
            URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&error_description=User%20said%20no")!
        )
        XCTAssertEqual(response.status, 400)
        do {
            _ = try await waiter.value
            XCTFail("expected providerDenied")
        } catch LoginError.providerDenied(let reason) {
            XCTAssertEqual(reason, "User said no")
        }
        let released = await AuthTestSupport.eventually(timeout: 5) { AuthTestSupport.isPortFree(port) }
        XCTAssertTrue(released)
    }

    func testTimeoutStopsTheListener() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        do {
            _ = try await server.waitForCode(timeout: 0.2)
            XCTFail("expected timeout")
        } catch LoginError.timeout {
            // expected
        }
        XCTAssertTrue(AuthTestSupport.isPortFree(port), "port must be free as soon as the timeout is reported")
    }

    func testCancellingTheWaiterStopsTheListener() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        let port = try await server.start()
        let waiter = Task { try await server.waitForCode(timeout: 10) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let released = await AuthTestSupport.eventually(timeout: 5) { AuthTestSupport.isPortFree(port) }
        XCTAssertTrue(released)
    }

    func testStopIsIdempotentAndReleasesThePort() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: ports, path: "/callback")
        _ = try await server.start()
        await server.stop()
        XCTAssertTrue(AuthTestSupport.isPortFree(1456), "port must be free once stop() returns")
        await server.stop()
        let port = await server.port
        XCTAssertEqual(port, 1456)
    }

    func testASecondListenerOnTheSamePortIsRefused() async throws {
        try requireFree(ports)
        let first = LoopbackCallbackServer(preferredPorts: [1456], path: "/callback")
        _ = try await first.start()
        let second = LoopbackCallbackServer(preferredPorts: [1456], path: "/callback")
        do {
            _ = try await second.start()
            XCTFail("two listeners must not share a port")
        } catch LoopbackError.portsBusy(let busy) {
            XCTAssertEqual(busy, [1456])
        }
        await first.stop()
        await second.stop()
    }

    func testPortIsReusableRightAfterAServedCallback() async throws {
        try requireFree(ports)
        let server = LoopbackCallbackServer(preferredPorts: [1456], path: "/callback")
        let port = try await server.start()
        let waiter = Task { try await server.waitForCode(timeout: 5) }
        _ = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(port)/callback?code=one")!)
        _ = try await waiter.value
        await server.stop()

        // The served connection may sit in TIME_WAIT; a new login must still bind.
        let again = LoopbackCallbackServer(preferredPorts: [1456], path: "/callback")
        let reboundPort = try await again.start()
        XCTAssertEqual(reboundPort, 1456)
        let secondWaiter = Task { try await again.waitForCode(timeout: 5) }
        let second = try await AuthTestSupport.get(URL(string: "http://127.0.0.1:\(reboundPort)/callback?code=two")!)
        XCTAssertEqual(second.status, 200)
        let callback = try await secondWaiter.value
        XCTAssertEqual(callback.code, "two")
        await again.stop()
    }
}
