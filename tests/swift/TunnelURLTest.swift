import Foundation

@main
struct TunnelURLTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let good = """
        2026-08-19T00:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-08-19T00:00:01Z INF |  https://alpha-123.trycloudflare.com  |
        """
        require(TunnelURL.firstTryCloudflareURL(in: good) == "https://alpha-123.trycloudflare.com", "valid quick-tunnel URL was not extracted")

        require(TunnelURL.firstTryCloudflareURL(in: "https://alpha-123.trycloudflare.com/") == "https://alpha-123.trycloudflare.com", "one trailing slash should normalize to the origin")
        require(TunnelURL.firstTryCloudflareURL(in: "HTTPS://ALPHA-123.TRYCLOUDFLARE.COM") == "https://alpha-123.trycloudflare.com", "scheme/host case should normalize")

        let rejected = [
            "https://evil.example/?next=https://alpha-123.trycloudflare.com",
            "https://evil.example@alpha-123.trycloudflare.com",
            "https://alpha-123.trycloudflare.com.evil.example",
            "https://alpha-123.trycloudflare.com:443",
            "http://alpha-123.trycloudflare.com",
            "https://alpha-123.trycloudflare.com/path",
            "https://alpha-123.trycloudflare.com?query=1",
            "https://alpha-123.trycloudflare.com#fragment",
            "https://-alpha.trycloudflare.com",
            "https://alpha-.trycloudflare.com",
            "https://a.b.trycloudflare.com",
            "not-a-url alpha-123.trycloudflare.com",
        ]
        for text in rejected {
            require(TunnelURL.firstTryCloudflareURL(in: text) == nil, "accepted hostile/non-origin input: \(text)")
        }

        let firstSafe = "noise https://evil.example then https://safe-one.trycloudflare.com later"
        require(TunnelURL.firstTryCloudflareURL(in: firstSafe) == "https://safe-one.trycloudflare.com", "should skip unrelated URLs and return the first exact quick-tunnel origin")

        print("tunnel-url: ok")
    }
}
