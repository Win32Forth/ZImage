import XCTest
@testable import ZImager

@MainActor
final class HelperClientTests: XCTestCase {
    func testReorgLampUsesTheHelperBit() throws {
        let raw = """
        {"reorgSafeToReboot":true,"runState":"plan_ready","phase":"Photos","pauseRequested":false,"move":1,"alreadyPlaced":0,"park":0,"leave":2,"cacheBytes":0,"rssBytes":0,"lastRecovery":"none"}
        """
        let status = try JSONDecoder().decode(ReorgStatus.self, from: Data(raw.utf8))
        XCTAssertEqual(ReorgCopy.lamp(nil), "Waiting for the helper.")
        XCTAssertEqual(ReorgCopy.lamp(status), "Safe to reboot")
        var unsafe = status
        unsafe.reorgSafeToReboot = false
        XCTAssertEqual(ReorgCopy.lamp(unsafe), "Not safe to reboot")
        XCTAssertEqual(ReorgCopy.cacheLine(status.cacheBytes), "Cache 0 bytes")
        XCTAssertEqual(ReorgCopy.cacheLine(4096), "Cache 4096 bytes")
        XCTAssertEqual(LibrarySidebar.items, ["Photos", "Review", "Duplicates"])
        let ready = ReorgActivity.readout(status: status, typedPrefix: "Photos", pending: nil)
        XCTAssertEqual(ready.activity, "Plan ready")
        XCTAssertEqual(ready.next, "Read Move, Already placed, Park, and Leave. Press Start to copy.")
        XCTAssertTrue(ready.showsCounts)
        let changed = ReorgActivity.readout(status: status, typedPrefix: "Photos/2025", pending: nil)
        XCTAssertFalse(changed.showsCounts)
        XCTAssertEqual(changed.countsNote, "Counts cleared. They were for Photos, not Photos/2025.")
        XCTAssertEqual(changed.next, "The folder changed to Photos/2025. Press Plan to count that folder.")
        XCTAssertEqual(changed.activity, "Plan ready")
        let slash = ReorgActivity.readout(status: status, typedPrefix: "Photos/", pending: nil)
        XCTAssertTrue(slash.showsCounts)
        var running = status
        running.runState = "running"
        running.reorgSafeToReboot = false
        let copying = ReorgActivity.readout(status: running, typedPrefix: "Photos", pending: .starting)
        XCTAssertEqual(copying.activity, "Copying")
        XCTAssertTrue(copying.showsCounts)
        let pressed = ReorgActivity.readout(status: status, typedPrefix: "Photos", pending: .starting)
        XCTAssertEqual(pressed.activity, "Starting")
        XCTAssertTrue(pressed.showsCounts)
        let waiting = ReorgActivity.readout(status: nil, typedPrefix: "Photos/2025", pending: .planning("Photos/2025"))
        XCTAssertEqual(waiting.activity, "Counting")
        XCTAssertFalse(waiting.showsCounts)
        XCTAssertEqual(waiting.countsNote, "")
        var planning = status
        planning.runState = "planning"
        planning.phase = "Photos"
        let counting = ReorgActivity.readout(status: planning, typedPrefix: "Photos/Scans", pending: .planning("Photos/Scans"))
        XCTAssertEqual(counting.activity, "Counting")
        XCTAssertFalse(counting.showsCounts)
        XCTAssertEqual(counting.countsNote, "")
        let known = ReorgActivity.readout(status: planning, typedPrefix: "Photos", pending: nil)
        XCTAssertEqual(known.activity, "Counting")
        XCTAssertFalse(known.showsCounts)
        var live = planning
        live.counting = true
        live.move = 4
        live.park = 1
        let ticking = ReorgActivity.readout(status: live, typedPrefix: "Photos", pending: .planning("Photos"))
        XCTAssertEqual(ticking.activity, "Counting")
        XCTAssertTrue(ticking.showsCounts)
        XCTAssertEqual(ReorgActivity.countingLine(status: nil, tick: 0), "Counting")
        XCTAssertEqual(ReorgActivity.countingLine(status: nil, tick: 4), "Counting 4s")
        live.seen = 26
        XCTAssertEqual(ReorgActivity.countingLine(status: live, tick: 4), "Counting 26")
        XCTAssertFalse(ReorgCopy.planTimedOut.contains("may"))
        var blocked = running
        blocked.runState = "blocked"
        let stopped = ReorgActivity.readout(status: blocked, typedPrefix: "Photos", pending: nil)
        XCTAssertEqual(stopped.activity, "Blocked")
        XCTAssertEqual(ReorgCopy.planFailure("prefix"), ReorgCopy.outsidePhotos)
        XCTAssertEqual(ReorgCopy.planFailure("busy"), "The plan was refused because reorganize is already running.")
        XCTAssertEqual(ReorgCopy.planFailure("catalog"), "The plan was not saved because the catalog could not be updated.")
        XCTAssertEqual(ReorgCopy.planFailure(nil), "The plan was refused and the helper did not say why. Nothing was copied.")
        XCTAssertEqual(ReorgCopy.actionFailure("trim", fallback: "idle"), "Refused because Trim is still running. Reorganize waits until Trim is idle.")
        XCTAssertEqual(ReorgCopy.actionFailure("plan", fallback: "idle"), "Refused because no Photos folder is saved. Press Plan first.")
        XCTAssertEqual(ReorgCopy.startNeedsPlan(typed: "Photos/2025", saved: "Photos"), "Start was not sent. The field is Photos/2025 and the saved plan is Photos. Press Plan for Photos/2025.")
        XCTAssertEqual(ReorgCopy.startNeedsPlan(typed: "Photos", saved: nil), "Start was not sent. Photos has no plan yet. Press Plan. Start only copies a folder after Plan saves it.")
        XCTAssertEqual(ReorgCopy.recoveryLine("none"), nil)
        XCTAssertEqual(ReorgCopy.recoveryLine("source_restored"), "Last recovery: the original was put back.")
        XCTAssertEqual(ReorgActivity.savedPlanLine("idle"), "Saved plan: none")
        XCTAssertEqual(ReorgActivity.savedPlanLine("Photos/2025"), "Saved plan: Photos/2025")
        var empty = status
        empty.phase = "Photos/Scans"
        empty.move = 0
        empty.alreadyPlaced = 0
        empty.park = 0
        empty.leave = 0
        let scans = ReorgActivity.readout(status: empty, typedPrefix: "Photos/Scans", pending: nil)
        XCTAssertEqual(scans.activity, "Plan ready")
        XCTAssertEqual(scans.next, "The catalog has no files under Photos/Scans, so every count is zero. Nothing will be copied.")
        XCTAssertTrue(scans.showsCounts)
        XCTAssertEqual(ReorgCopy.statusFault(URLError(.timedOut)), ReorgCopy.statusCheckTimedOut)
        XCTAssertFalse(ReorgCopy.statusCheckTimedOut.contains("counting"))
        XCTAssertEqual(ReorgCopy.statusFault(HelperError.offline), ReorgCopy.statusCheckSilent)
        XCTAssertEqual(ReorgCopy.lamp(nil), "Waiting for the helper.")
        XCTAssertEqual(ReorgCopy.safe, "Safe to reboot")
        XCTAssertEqual(ReorgCopy.unsafe, "Not safe to reboot")
    }

    func testTrimLampUsesTheTrimBit() throws {
        let raw = """
        {"safeToReboot":true,"runState":"idle","pauseRequested":false,"eligible":1,"moved":0,"waiting":2}
        """
        let status = try JSONDecoder().decode(TrimStatus.self, from: Data(raw.utf8))
        XCTAssertEqual(TrimCopy.lamp(nil), "Waiting for the helper.")
        XCTAssertEqual(TrimCopy.lamp(status), "Safe to reboot")
        var unsafe = status
        unsafe.safeToReboot = false
        XCTAssertEqual(TrimCopy.lamp(unsafe), "Not safe to reboot")
        XCTAssertEqual(LibrarySidebar.items, ["Photos", "Review", "Duplicates"])
    }

    func testNothingAnswersShowsEmptyOffline() async {
        let fake = FakeHelperListener()
        let session = LibrarySession(client: client(fake: fake))
        await session.refresh()
        XCTAssertTrue(session.isEmptyOffline)
        XCTAssertNil(session.banner)
        XCTAssertTrue(session.rows.isEmpty)
        XCTAssertFalse(session.writesEnabled)
        _ = LibraryEmptyState()
        XCTAssertNotEqual(LibraryCopy.emptyTitle, LibraryCopy.staleBanner)
        XCTAssertEqual(fake.callCount(), 1)
    }

    func testLoadedPageThenSilenceShowsStaleBanner() async {
        let fake = FakeHelperListener()
        let page = Data(#"{"rows":[{"uid":"asset-1"}],"nextCursor":""}"#.utf8)
        fake.enqueue(.success(HelperResponse(status: 200, body: page)))
        fake.enqueue(.failure(URLError(.cannotConnectToHost)))
        let session = LibrarySession(client: client(fake: fake))
        await session.refresh()
        XCTAssertEqual(session.rows.map(\.uid), ["asset-1"])
        XCTAssertTrue(session.writesEnabled)
        XCTAssertNil(session.banner)

        await session.refresh()
        XCTAssertEqual(session.rows.map(\.uid), ["asset-1"])
        XCTAssertFalse(session.writesEnabled)
        XCTAssertFalse(session.isEmptyOffline)
        XCTAssertEqual(session.banner, LibraryCopy.staleBanner)
        XCTAssertEqual(
            session.banner,
            "Helper offline. This grid is the last response and is not a saved catalog."
        )
        let banner = OfflineBanner(text: session.banner ?? "")
        XCTAssertEqual(banner.text, LibraryCopy.staleBanner)
    }

    func testNameAndIPv6AreNotDialed() async {
        let fake = FakeHelperListener()
        let named = HelperClient(
            credentials: HelperCredentials(host: "DS423._smb._tcp.local", token: "t"),
            send: { request in
                try await fake.send(request)
            }
        )
        do {
            _ = try await named.assets()
            XCTFail("dialed a name")
        } catch HelperError.notIPv4 {
            XCTAssertEqual(HelperError.notIPv4.message, "Helper address is not IPv4")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(fake.callCount(), 0)

        let stored = client(fake: fake)
        do {
            try stored.prepareDial(to: "10.1.1.1")
            XCTFail("dialed a different host")
        } catch HelperError.hostChanged {
            XCTAssertEqual(HelperError.hostChanged.message, "Helper address changed. Pair again.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(fake.callCount(), 0)
        XCTAssertThrowsError(try HelperClient.firstIPv4(from: ["fe80::1"])) { error in
            XCTAssertEqual(error as? HelperError, .notIPv4)
        }
        XCTAssertEqual(try HelperClient.firstIPv4(from: ["fe80::1", "192.168.1.9"]), "192.168.1.9")
        XCTAssertFalse(HelperClient.isIPv4("::1"))
        XCTAssertFalse(HelperClient.isIPv4("01.2.3.4"))
        XCTAssertTrue(HelperClient.isIPv4("192.168.0.1"))
    }

    func testPinMatchesTheSharedVectorAndRejectsAChange() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.spkiFixtureDER))
        let hash = try XCTUnwrap(CertificatePin.sha256(certificateDER: der))
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(), Self.spkiFixtureHash)

        let fake = FakeHelperListener()
        let client = client(fake: fake, pin: Data())
        try client.acceptCertificate(der)
        XCTAssertEqual(client.credentials.pin, hash)
        // The pin is the SPKI. The last byte is the signature, so it still matches.
        var signatureOnly = der
        signatureOnly[signatureOnly.count - 1] ^= 0xFF
        try client.acceptCertificate(signatureOnly)
        XCTAssertEqual(client.credentials.pin, hash)
        // Byte 160 is inside the P-256 public key.
        var flipped = der
        flipped[160] ^= 0xFF
        XCTAssertThrowsError(try client.acceptCertificate(flipped)) { error in
            XCTAssertEqual(error as? HelperError, .pinChanged)
        }
        XCTAssertEqual(client.credentials.pin, hash)
    }

    func testPairingFileAndMemoryStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zimage-pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".zimage"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tokenURL = root.appendingPathComponent(".zimage/PAIRING-TOKEN")
        try Data("pair-token\n".utf8).write(to: tokenURL)
        XCTAssertEqual(try PairingFile.token(inLibraryRoot: root), "pair-token")

        var store = MemoryTokenStore()
        let secret = StoredSecret(token: "pair-token", pinBase64: Self.spkiFixtureHash)
        store.save(host: "192.168.1.20", secret: secret)
        XCTAssertEqual(store.load(host: "192.168.1.20"), secret)
        XCTAssertNil(store.load(host: "10.0.0.8"))
        XCTAssertEqual(KeychainTokenStore.service, "ZImage NAS Helper")
    }

    func testTrustOnFirstUseLearnsThePin() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.spkiFixtureDER))
        var pin = Data()
        XCTAssertTrue(CertificateTrust.decide(pin: &pin, certificateDER: der))
        XCTAssertEqual(pin.map { String(format: "%02x", $0) }.joined(), Self.spkiFixtureHash)
        var stored = pin
        XCTAssertTrue(CertificateTrust.decide(pin: &stored, certificateDER: der))
        var flipped = der
        flipped[160] ^= 0xFF
        XCTAssertFalse(CertificateTrust.decide(pin: &stored, certificateDER: flipped))
        XCTAssertEqual(stored, pin)
    }

    func testClaimAcceptsNoContentAndRejectsARefusal() async throws {
        let fake = FakeHelperListener()
        fake.enqueue(.success(HelperResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))))
        let helper = client(fake: fake)
        do {
            try await helper.claim(pairingToken: "pair-token")
            XCTFail("accepted a refusal")
        } catch HelperError.unauthorized {
            XCTAssertEqual(HelperError.unauthorized.message, "Helper refused the token.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        fake.enqueue(.success(HelperResponse(status: 204, body: Data())))
        try await helper.claim(pairingToken: "pair-token")
    }

    func testEditorClaimsStillImagesWithoutBecomingTheDefault() throws {
        let bundle = Bundle(identifier: "com.Win32Forth.ZImager") ?? Bundle.main
        let types = try XCTUnwrap(bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let claimed = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for uti in ["public.jpeg", "public.png", "public.heic", "public.tiff", "public.camera-raw-image", "com.adobe.pdf"] {
            XCTAssertTrue(claimed.contains(uti), uti)
        }
        XCTAssertTrue(claimed.contains(ZImgRaw.contentTypeIdentifier))
        for type in types {
            let rank = type["LSHandlerRank"] as? String
            let ids = type["LSItemContentTypes"] as? [String] ?? []
            if ids.contains(ZImgRaw.contentTypeIdentifier) {
                XCTAssertEqual(rank, "Owner")
                XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Editor")
            } else {
                XCTAssertEqual(rank, "Alternate")
            }
        }
        let exported = try XCTUnwrap(bundle.infoDictionary?["UTExportedTypeDeclarations"] as? [[String: Any]])
        let zimg = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == ZImgRaw.contentTypeIdentifier })
        let tags = try XCTUnwrap(zimg["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["zimg"])
        XCTAssertEqual(bundle.infoDictionary?["LSMultipleInstancesProhibited"] as? Bool, true)
    }

    func testHandoffTargetsTheEditor() {
        let file = URL(fileURLWithPath: "/Volumes/BackupData/PhotoVideoAudio/Photos/a.jpg")
        var opened: (URL, String)?
        EditorHandoff.openFile(file) { url, bundleID in
            opened = (url, bundleID)
        }
        XCTAssertEqual(opened?.0, file)
        XCTAssertEqual(opened?.1, "com.Win32Forth.ZImager")
        XCTAssertFalse(FeatureFlags().reorgExecution)
        XCTAssertFalse(FeatureFlags().trimExecution)

        let running = URL(fileURLWithPath: "/tmp/DerivedData/ZImage.app")
        let registered = URL(fileURLWithPath: "/Applications/ZImage.app")
        XCTAssertEqual(EditorHandoff.applicationURL(running: [running], registered: registered), running)
        XCTAssertEqual(EditorHandoff.applicationURL(running: [], registered: registered), registered)
        XCTAssertNil(EditorHandoff.applicationURL(running: [], registered: nil))
    }

    private func client(fake: FakeHelperListener, pin: Data = Data([1])) -> HelperClient {
        HelperClient(credentials: HelperCredentials(host: "192.168.1.20", pin: pin, token: "t")) { request in
            try await fake.send(request)
        }
    }

    private static let spkiFixtureDER = "MIIBZDCCAQqgAwIBAgIUNlSzFwYJLw+rDSFKft3vXwJJeBkwCgYIKoZIzj0EAwIwGDEWMBQGA1UEAwwNemltYWdlLWhlbHBlcjAeFw0yNjExMDQyMDQwMTNaFw0zNjExMDEyMDQwMTNaMBgxFjAUBgNVBAMMDXppbWFnZS1oZWxwZXIwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASAh28MWcMUEIi4EeFOmndNwihYO3j/EHoJDQ3KYpBrcdRM6ssKJ9s1WhdAxVZwiOKdcwONi8esfapFsUV9jhm8ozIwMDAdBgNVHQ4EFgQU05uhnItnhnJURyWj30faRsAFkX0wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiAZVFkKVmmC0sNYjCr/U4q9Cl1lxTn2T3znsHfYF/jVHAIhAIlfIeJZeeS5HimkG+ythEz/xyGh17a7Yyi0DRfTpjPk"
    private static let spkiFixtureHash = "7d575f8bf6bf272ce9febb428f132ca251f0235951cd06ad7a72a76389af2166"
}

private final class FakeHelperListener: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var script: [Result<HelperResponse, Error>] = []

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func enqueue(_ result: Result<HelperResponse, Error>) {
        lock.lock()
        script.append(result)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> HelperResponse {
        let next = takeNext()
        guard let next else { throw URLError(.cannotConnectToHost) }
        return try next.get()
    }

    private func takeNext() -> Result<HelperResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return script.isEmpty ? nil : script.removeFirst()
    }
}
