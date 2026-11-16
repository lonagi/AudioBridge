using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

static class UpdateTests
{
    static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void Rejected(Action action, string name)
    {
        bool rejected = false; try { action(); } catch (IOException) { rejected = true; }
        Require(rejected, "Accepted invalid package: " + name);
    }
    public static void Filesystem()
    {
        string root = Path.Combine(Directory.GetCurrentDirectory(), "update-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        byte[] MakeZip(string name, bool duplicate = false) {
            using var memory = new MemoryStream();
            using (var zip = new ZipArchive(memory, ZipArchiveMode.Create, true)) {
                var bytes = new byte[2048]; bytes[0] = (byte)'M'; bytes[1] = (byte)'Z';
                using (var stream = zip.CreateEntry(name).Open()) stream.Write(bytes);
                if (duplicate) using (var stream = zip.CreateEntry(name).Open()) stream.Write(bytes);
            }
            return memory.ToArray();
        }
        string target = Path.Combine(root, "WindowsAudio.exe"); File.WriteAllText(target, "old");
        var valid = MakeZip("WindowsAudio.exe");
        string stage = UpdateApply.StagePackage(valid, UpdateProtocol.Hash(valid), target, "0.4.0");
        Require(File.Exists(Path.Combine(stage, "plan.json")), "Missing update plan");
        Rejected(() => UpdateApply.StagePackage(valid, new string('0', 64), target, "0.4.0"), "wrong hash");
        foreach (var name in new[] { "../WindowsAudio.exe", @"..\WindowsAudio.exe", "C:WindowsAudio.exe" }) {
            var bytes = MakeZip(name); Rejected(() => UpdateApply.StagePackage(bytes, UpdateProtocol.Hash(bytes), target, "0.4.0"), name);
        }
        var duplicate = MakeZip("WindowsAudio.exe", true);
        Rejected(() => UpdateApply.StagePackage(duplicate, UpdateProtocol.Hash(duplicate), target, "0.4.0"), "duplicate");
        string replacement = Path.Combine(root, "next.exe"); File.WriteAllText(replacement, "new");
        bool restarted = false;
        Rejected(() => UpdateApply.ReplaceWithRollback(target, replacement, () => false, () => restarted = true), "failed health check");
        Require(restarted && File.ReadAllText(target) == "old", "Rollback did not restore old executable");
        File.WriteAllText(replacement, "new"); restarted = false;
        UpdateApply.ReplaceWithRollback(target, replacement, () => true, () => restarted = true);
        Require(!restarted && File.ReadAllText(target) == "new" && File.ReadAllText(target + ".previous") == "old", "Successful replacement failed");
        Rejected(() => UpdateApply.ReplaceWithRollback(target, "missing-file", () => true, () => restarted = true), "missing staged file");
        Require(restarted && File.ReadAllText(target) == "new", "Failure before replace did not restart old binary");
        Program.Log("PASS: package hash/path/duplicate checks, staging, successful replacement, rollback, and restart on pre-replacement failure");
    }
    public static async Task Http(Config config)
    {
        byte[] key = Convert.FromBase64String(config.Key);
        using var http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false });
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var ct = timeout.Token;
        byte[] Body(string request = "", string state = "Ready") => JsonSerializer.SerializeToUtf8Bytes(new { ClientId = "integration-test", Name = "Test Windows", Version = "0.2.0", State = state, Message = "", RequestId = request });
        async Task<UpdateManifest> Report(byte[] body) => JsonSerializer.Deserialize<UpdateManifest>(await UpdateProtocol.Fetch(http, IPAddress.Loopback, key, "POST", "/api/status", body, ct, 8766))!;
        var manifest = await Report(Body());
        Require(manifest.Version == UpdateProtocol.Version, "Manifest version mismatch");
        await Task.Delay(1200, ct);
        manifest = await Report(Body());
        Require(manifest.RequestId.Length > 0, "Mac update request not received");
        var bytes = await UpdateProtocol.Fetch(http, IPAddress.Loopback, key, "GET", "/api/package", [], ct, 8766);
        Require(bytes.LongLength == manifest.Size && UpdateProtocol.Hash(bytes) == manifest.Sha256, "Downloaded package differs from manifest");
        var ack = await Report(Body(manifest.RequestId, "Downloading"));
        Require(ack.RequestId == "", "Request acknowledgement failed");
        bool rejected = false;
        try { await UpdateProtocol.Fetch(http, IPAddress.Loopback, RandomNumberGenerator.GetBytes(32), "GET", "/api/package", [], ct, 8766); }
        catch (CryptographicException) { rejected = true; }
        Require(rejected, "Wrong key accepted");
        string nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        async Task<int> Repeat() {
            using var req = new HttpRequestMessage(HttpMethod.Post, "http://127.0.0.1:8766/api/status");
            var body = Body(); req.Content = new ByteArrayContent(body);
            req.Headers.Add("X-AB-Nonce", nonce); req.Headers.Add("X-AB-Auth", UpdateProtocol.RequestMac(key, "POST", "/api/status", nonce, body));
            using var response = await http.SendAsync(req, ct); return (int)response.StatusCode;
        }
        Require(await Repeat() == 200 && await Repeat() == 401, "Replay request accepted");
        Program.Log("PASS: authenticated C# ↔ Swift HTTP, Mac update request/ack, archive download/hash, wrong-key and replay rejection");
    }
}
