using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

static class UpdateProtocol
{
    public static string Version => typeof(UpdateProtocol).Assembly.GetName().Version!.ToString(3);
    public static string Hash(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    static string Mac(byte[] key, string text) => Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    public static string RequestMac(byte[] key, string method, string path, string nonce, byte[] body) =>
        Mac(key, $"AB-REQ/1\n{method}\n{path}\n{nonce}\n{Hash(body)}");
    public static string ResponseMac(byte[] key, int status, string nonce, byte[] body) =>
        Mac(key, $"AB-RESP/1\n{status}\n{nonce}\n{Hash(body)}");
    public static bool Equal(string left, string right)
    {
        try { return CryptographicOperations.FixedTimeEquals(Convert.FromHexString(left), Convert.FromHexString(right)); }
        catch { return false; }
    }
    public static async Task<byte[]> Fetch(HttpClient client, IPAddress address, byte[] key, string method, string path, byte[] body, CancellationToken ct, int port = 8765)
    {
        var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        using var request = new HttpRequestMessage(new HttpMethod(method), new UriBuilder("http", address.ToString(), port, path).Uri);
        request.Headers.Add("X-AB-Nonce", nonce);
        request.Headers.Add("X-AB-Auth", RequestMac(key, method, path, nonce, body));
        if (body.Length > 0) request.Content = new ByteArrayContent(body);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        long maximum = path == "/api/package" ? 150L * 1024 * 1024 : 32 * 1024;
        if (response.Content.Headers.ContentLength is > 0 && response.Content.Headers.ContentLength > maximum) throw new IOException("Update response too large");
        using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var data = new MemoryStream(); var buffer = new byte[65536];
        while (true) {
            int count = await stream.ReadAsync(buffer, ct); if (count == 0) break;
            if (data.Length + count > maximum) throw new IOException("Update response exceeds limit");
            data.Write(buffer, 0, count);
        }
        var bytes = data.ToArray();
        if (!response.Headers.TryGetValues("X-AB-Auth", out var values) ||
            !Equal(ResponseMac(key, (int)response.StatusCode, nonce, bytes), values.Single())) throw new CryptographicException("Mac response authentication failed");
        response.EnsureSuccessStatusCode();
        return bytes;
    }
}
