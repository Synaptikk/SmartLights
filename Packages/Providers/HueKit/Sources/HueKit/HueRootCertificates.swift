import Foundation
import NetKit

/// Signify root CAs bundled in `Resources/hue-roots.pem`.
public enum HueRootCertificates {
    /// PEM text of the bundled roots (empty string if the resource is missing).
    public static var pem: String {
        guard let url = Bundle.module.url(forResource: "hue-roots", withExtension: "pem"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// DER of every certificate in the bundle (1 today: `root-bridge`; the Bridge Pro root is a TODO).
    public static var derCertificates: [Data] { PEM.certificates(from: pem) }
}

/// Counting semaphore for "at most N concurrent requests per bridge" (aiohue: 3).
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = max(1, count) }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
