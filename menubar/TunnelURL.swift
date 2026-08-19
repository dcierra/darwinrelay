import Foundation

enum TunnelURL {
    /// Extract the first exact Cloudflare Quick Tunnel origin from arbitrary
    /// cloudflared log text.
    ///
    /// Treat the log as untrusted text: detect URLs first, parse them, then
    /// validate URL components and host labels structurally. Do not use a regex
    /// that merely finds `https://*.trycloudflare.com` as a substring of a
    /// different URL.
    static func firstTryCloudflareURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: fullRange) {
            guard let url = match.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.user == nil,
                  components.password == nil,
                  components.port == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  let rawHost = components.host
            else { continue }

            let host = rawHost.lowercased()
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count == 3,
                  labels[1] == "trycloudflare",
                  labels[2] == "com"
            else { continue }

            let tunnelLabel = labels[0]
            guard !tunnelLabel.isEmpty,
                  tunnelLabel.count <= 63,
                  tunnelLabel.first != "-",
                  tunnelLabel.last != "-",
                  tunnelLabel.allSatisfy({ ch in
                      ch == "-" || ch.isASCII && (ch.isLowercase || ch.isNumber)
                  })
            else { continue }

            return "https://\(host)"
        }
        return nil
    }
}
