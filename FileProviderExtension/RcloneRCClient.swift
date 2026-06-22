import Foundation

/// Thin async client over rclone's remote-control (RC) HTTP API, served by a
/// `rclone rcd --rc-addr=127.0.0.1:<port> --rc-no-auth` daemon that the **host app**
/// launches (the sandboxed extension must not spawn the CLI itself).
///
/// This is the single seam between the File Provider extension and rclone. To later
/// run rclone in-process via `librclone`, replace the `post` implementation with a
/// `RcloneRPC.call(method:input:)` FFI call — the rest of the extension is unchanged.
///
/// NOTE(mac): not yet compiled — see FileProviderExtension/README.md.
struct RcloneRCClient {
    let baseURL: URL
    let session: URLSession

    init(port: Int, session: URLSession = .shared) {
        // swiftlint:disable:next force_unwrapping
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    enum RCError: Error {
        case http(status: Int, body: String)
        case decoding(Error)
        case transport(Error)
    }

    /// One rclone listing entry (subset of `operations/list` output).
    struct ListEntry: Decodable {
        let Path: String
        let Name: String
        let Size: Int64
        let MimeType: String?
        let ModTime: String?   // RFC3339
        let IsDir: Bool
        let ID: String?
    }

    /// POST a JSON body to an RC endpoint like "operations/list" and decode the result.
    func post<Output: Decodable>(
        _ endpoint: String,
        _ body: [String: Any],
        as: Output.Type
    ) async throws -> Output {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RCError.transport(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RCError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(Output.self, from: data)
        } catch {
            throw RCError.decoding(error)
        }
    }

    // MARK: - High-level operations

    private struct ListResult: Decodable { let list: [ListEntry] }

    /// List a single directory level under `fs` at `remote` (non-recursive).
    /// `fs` is the rclone remote (e.g. "mydrive:"), `remote` the path within it.
    func list(fs: String, remote: String) async throws -> [ListEntry] {
        try await post(
            "operations/list",
            ["fs": fs, "remote": remote, "opt": ["recurse": false]],
            as: ListResult.self
        ).list
    }

    /// Download an object's bytes. For large files prefer a ranged streaming read;
    /// `operations/cat` is sufficient for v1 small/medium files.
    /// TODO(mac): switch to a ranged fetch for `fetchPartialContents`.
    func cat(fs: String, remote: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("operations/cat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fs": fs, "remote": remote])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RCError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
