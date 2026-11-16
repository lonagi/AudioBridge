using System.Buffers.Binary;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

static class MicrophoneTests
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    sealed class FakeDefaults : ICaptureDefaults
    {
        public string[] Values = ["original-console", "original-media", "original-chat"];
        public int FailRole = -1;
        public string? Get(int role) => Values[role];
        public void Set(int role, string id) { if (role == FailRole && id == "virtual") throw new IOException("Simulated failure"); Values[role] = id; }
    }
    public static void Defaults()
    {
        string folder = Path.Combine(Path.GetTempPath(), "AudioBridge-test-" + Guid.NewGuid().ToString("N"));
        string path = Path.Combine(folder, "defaults.json");
        try {
            var backend = new FakeDefaults(); var original = backend.Values.ToArray();
            var lease = new CaptureDefaultLease(backend, path);
            lease.Acquire("virtual"); Check(lease.IsDefault("virtual") && File.Exists(path), "Did not acquire all roles");
            backend.Values[2] = "manual-user-selection";
            lease.Acquire("virtual"); Check(backend.Values[2] == "manual-user-selection", "Overrode manual selection");
            lease.Restore(); Check(backend.Values[0] == original[0] && backend.Values[1] == original[1] && backend.Values[2] == "manual-user-selection" && !File.Exists(path), "Restore clobbered user selection");
            lease.Acquire("virtual"); _ = new CaptureDefaultLease(backend, path);
            Check(backend.Values[0] == original[0] && backend.Values[2] == "manual-user-selection" && !File.Exists(path), "Crash recovery failed");
            lease = new CaptureDefaultLease(backend, path); backend.FailRole = 1;
            bool failed = false; try { lease.Acquire("virtual"); } catch (IOException) { failed = true; }
            Check(failed && backend.Values[0] == original[0] && !File.Exists(path), "Partial failure did not roll back");
            Program.Log("PASS: default capture roles, manual selection preserved, crash recovery and partial-change rollback");
        } finally { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
    }
    public static void Fixture(Config config)
    {
        var key = MicProtocol.Key(Convert.FromBase64String(config.Key), "0123456789abcdef0123456789abcdef");
        var frame = File.ReadAllBytes("mic-fixture.bin");
        Check(BinaryPrimitives.ReadUInt16LittleEndian(frame) == frame.Length - 2, "Length mismatch");
        var packet = frame[2..]; var decoded = MicProtocol.Decode(packet, key, 0);
        Check(decoded.Rate == 48000 && BinaryPrimitives.ReadInt16LittleEndian(decoded.Pcm) == 1234 && BinaryPrimitives.ReadInt16LittleEndian(decoded.Pcm.AsSpan(2)) == -2345, "PCM mismatch");
        void Reject(Action action) { bool rejected = false; try { action(); } catch { rejected = true; } Check(rejected, "Invalid microphone frame accepted"); }
        Reject(() => MicProtocol.Decode(packet, key, 1));
        Reject(() => MicProtocol.Decode(packet, RandomNumberGenerator.GetBytes(32), 0));
        Reject(() => MicProtocol.Decode(packet, MicProtocol.Key(Convert.FromBase64String(config.Key), Guid.NewGuid().ToString("N")), 0));
        var altered = packet.ToArray(); altered[20] ^= 1; Reject(() => MicProtocol.Decode(altered, key, 0));
        var reflected = packet.ToArray(); "WAM1"u8.CopyTo(reflected); Reject(() => MicProtocol.Decode(reflected, key, 0));
        Program.Log("PASS: Swift → C# microphone PCM, replay sequence, altered packet, wrong key/stream and reflected audio rejection");
    }
    public static async Task Http(Config config)
    {
        using var http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false });
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(20)); var ct = cancel.Token;
        var key = Convert.FromBase64String(config.Key);
        string session = Guid.NewGuid().ToString("N");
        async Task<MicSnapshot> Report(MicCommand? command = null) {
            var body = JsonSerializer.SerializeToUtf8Bytes(new { ClientId = "mic-integration", Name = "Test PC", Version = "0.4.0", State = "Ready", Message = "", RequestId = "", Microphone = new MicReport(session, [new MicOutput("virtual", "Virtual Mic", "Virtual Mic for AudioRelay")], command, "", -1) });
            var manifest = JsonSerializer.Deserialize<UpdateManifest>(await UpdateProtocol.Fetch(http, IPAddress.Loopback, key, "POST", "/api/status", body, ct, 8766));
            return manifest!.Microphone!;
        }
        async Task<HttpResponseMessage> Stream(string streamId, string claimedSession) {
            var body = JsonSerializer.SerializeToUtf8Bytes(new { ClientId = "mic-integration", Session = claimedSession, Stream = streamId });
            string nonce = Guid.NewGuid().ToString("N");
            using var request = new HttpRequestMessage(HttpMethod.Post, "http://127.0.0.1:8766/api/microphone");
            request.Content = new ByteArrayContent(body); request.Headers.Add("X-AB-Nonce", nonce);
            request.Headers.Add("X-AB-Auth", UpdateProtocol.RequestMac(key, "POST", "/api/microphone", nonce, body));
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.IsSuccessStatusCode)
                Check(response.Headers.TryGetValues("X-AB-Auth", out var tags) && UpdateProtocol.Equal(tags.Single(), UpdateProtocol.ResponseMac(key, 200, nonce, [])), "Stream handshake signature mismatch");
            return response;
        }
        var initial = await Report(); Check(!initial.Enabled && initial.Sources.Length == 2, "Microphone enabled by default");
        using (var disabled = await Stream(Guid.NewGuid().ToString("N"), session)) Check(disabled.StatusCode == HttpStatusCode.Unauthorized, "Disabled mic stream accepted");
        var enabled = await Report(new MicCommand("enable", true, "builtin", "virtual"));
        Check(enabled.Enabled && enabled.OutputId == "virtual", "Enable command failed");
        using (var wrong = await Stream(Guid.NewGuid().ToString("N"), "wrong-session")) Check(wrong.StatusCode == HttpStatusCode.Unauthorized, "Other session accepted");
        string streamId = Guid.NewGuid().ToString("N");
        using (var response = await Stream(streamId, session)) {
            response.EnsureSuccessStatusCode(); await using var stream = await response.Content.ReadAsStreamAsync(ct);
            byte[] prefix = new byte[2]; await stream.ReadExactlyAsync(prefix, ct);
            byte[] packet = new byte[BinaryPrimitives.ReadUInt16LittleEndian(prefix)]; await stream.ReadExactlyAsync(packet, ct);
            var decoded = MicProtocol.Decode(packet, MicProtocol.Key(key, streamId), 0);
            Check(decoded.Rate == 48000 && decoded.Pcm.Length == 960 && decoded.Pcm.All(b => b == 0), "Synthetic microphone frame mismatch");
            var stopped = await Report(new MicCommand("stop", false)); Check(!stopped.Enabled, "Disable failed");
        }
        using (var disabled = await Stream(Guid.NewGuid().ToString("N"), session)) Check(disabled.StatusCode == HttpStatusCode.Unauthorized, "Disabled stream accepted after stop");
        Program.Log("PASS: authenticated microphone enable/stop, default off, session binding, signed streaming handshake and encrypted HTTP audio frame");
    }
}
