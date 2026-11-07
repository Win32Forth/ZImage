import Foundation
import Security

/// Live helper transport. Launch uses this only when an IPv4 host and a pin are already stored.
final class PinnedHelperSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var pin: Data
    private var session: URLSession!

    init(pin: Data) {
        self.pin = pin
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    var acceptedPin: Data {
        lock.lock()
        defer { lock.unlock() }
        return pin
    }

    func send(_ request: URLRequest) async throws -> HelperResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HelperResponse(status: status, body: data)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(certificate) as Data
        lock.lock()
        var known = pin
        let accepted = CertificateTrust.decide(pin: &known, certificateDER: der)
        if accepted {
            pin = known
        }
        lock.unlock()
        guard accepted else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
