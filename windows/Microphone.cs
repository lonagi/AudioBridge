using System.Buffers.Binary;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;

record MicSource(string Id, string Name, bool Available);
record MicOutput(string Id, string Name, string InputName = "");
record MicCommand(string Id, bool? Enabled = null, string? Source = null, string? OutputId = null);
record MicTelemetry(string Input, bool IsDefault, float InputPeak, long InputFrames, long ReceivedFrames, string DefaultsStatus);
record MicReport(string Session, MicOutput[] Outputs, MicCommand? Command, string Status, int Revision, MicTelemetry? Telemetry = null);
record MicSnapshot(bool Enabled, string Source, string OutputId, MicSource[] Sources, string Status, string CommandId, int Revision);
record MicPreferences(string Source, string OutputId);

static class MicProtocol
{
    public static byte[] Key(byte[] pairing, string stream) => SHA256.HashData(pairing.Concat(Encoding.UTF8.GetBytes("AudioBridge microphone v1\n" + stream)).ToArray());
    public static (int Rate, byte[] Pcm) Decode(byte[] packet, byte[] key, ulong expected)
    {
        if (packet.Length < 34 || packet.Length > 992 || !packet.AsSpan(0, 4).SequenceEqual("ABM1"u8) ||
            BinaryPrimitives.ReadUInt64LittleEndian(packet.AsSpan(4)) != expected || (packet.Length - 32) % 2 != 0)
            throw new IOException("Invalid microphone frame");
        int rate = BinaryPrimitives.ReadInt32LittleEndian(packet.AsSpan(12));
        if (rate is < 8000 or > 192000) throw new IOException("Invalid microphone rate");
        byte[] nonce = new byte[12]; packet.AsSpan(4, 8).CopyTo(nonce.AsSpan(4));
        byte[] pcm = new byte[packet.Length - 32];
        using var aes = new AesGcm(key, 16);
        aes.Decrypt(nonce, packet.AsSpan(16, pcm.Length), packet.AsSpan(packet.Length - 16), pcm, packet.AsSpan(0, 16));
        return (rate, pcm);
    }
}

sealed class MicrophoneClient : IDisposable
{
    readonly object sync = new();
    readonly byte[] key;
    readonly string clientId;
    readonly string session = Guid.NewGuid().ToString("N");
    readonly HttpClient http = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
    readonly Queue<(MicCommand Command, long Created)> commands = new();
    readonly string preferencesPath = Path.Combine(Startup.Folder, "microphone.json");
    CancellationTokenSource? streamCancel;
    Task? streamTask;
    string signature = "";
    string status = "Микрофон выключен";
    MicSnapshot? state;
    MicOutput[] outputs = [];
    long lastOutputs;
    long lastContact;
    bool disposed;
    MicPreferences? preferences;
    bool restorePreferences = true;
    CaptureDefaultLease? defaults;
    AudioRelayMicrophone? activeSink;
    string activeInput = "";
    long receivedFrames;
    string defaultsError = "";
    CaptureDefaultLease DefaultLease => defaults ??= new CaptureDefaultLease(new WindowsCaptureDefaults(), Path.Combine(Startup.Folder, "microphone-defaults.json"));
    void RestoreDefaults() {
        if (!OperatingSystem.IsWindows()) return;
        try { DefaultLease.Restore(); defaultsError = ""; }
        catch (Exception e) { defaultsError = e.Message; Program.Log("Возврат микрофона Windows: " + e.Message); }
    }
    public MicSnapshot? State { get { lock (sync) return state; } }
    public string Status { get { lock (sync) return status; } }
    public MicOutput[] Outputs { get { lock (sync) return outputs.ToArray(); } }
    public MicrophoneClient(byte[] key, string clientId)
    {
        this.key = key; this.clientId = clientId;
        RestoreDefaults();
        try {
            preferences = JsonSerializer.Deserialize<MicPreferences>(File.ReadAllText(preferencesPath));
        } catch { }
    }
    public void Queue(bool? enabled = null, string? source = null, string? output = null)
    {
        lock (sync) {
            restorePreferences = false;
            if (enabled == false) { commands.Clear(); StopStream(); RestoreDefaults(); status = "Микрофон выключен"; }
            if (source != null || output != null) StopStream();
            if (enabled == true) status = "Подключение микрофона…";
            if (commands.Count >= 16) commands.Dequeue();
            commands.Enqueue((new MicCommand(Guid.NewGuid().ToString("N"), enabled, source, output), Environment.TickCount64));
        }
    }
    public MicReport Report()
    {
        lock (sync) {
            if (Environment.TickCount64 - lastOutputs > 3000) {
                try {
                    if (OperatingSystem.IsWindows()) {
                        using var devices = new MMDeviceEnumerator();
                        outputs = devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
                            .Select(d => { using (d) return new MicOutput(d.ID, d.FriendlyName, d.FriendlyName); })
                            .Where(d => d.InputName.Contains("Virtual Mic for AudioRelay", StringComparison.OrdinalIgnoreCase))
                            .OrderBy(d => d.Id, StringComparer.Ordinal).Take(1).ToArray();
                    }
                    lastOutputs = Environment.TickCount64;
                } catch { outputs = []; }
            }
            while (commands.Count > 0 && Environment.TickCount64 - commands.Peek().Created > 15000) commands.Dequeue();
            // Restore only after the first usable connection, not 15 seconds after Windows starts.
            if (restorePreferences && preferences != null && state != null)
                Queue(source: preferences.Source);
            bool isDefault = false;
            try { isDefault = activeInput.Length > 0 && DefaultLease.IsDefault(activeInput); } catch { }
            var telemetry = new MicTelemetry(outputs.FirstOrDefault(o => o.Id == activeInput)?.InputName ?? "", isDefault,
                activeSink?.TakePeak() ?? 0, activeSink?.InputFrames ?? 0, receivedFrames,
                defaultsError.Length > 0 ? defaultsError : defaults?.Status ?? "Не изменён");
            return new MicReport(session, outputs, commands.Count > 0 ? commands.Peek().Command : null, status, state?.Revision ?? -1, telemetry);
        }
    }
    public void Apply(MicSnapshot? next, IPAddress address)
    {
        lock (sync) {
            if (disposed) return;
            lastContact = Environment.TickCount64;
            if (next is { CommandId.Length: 0 } && preferences != null && commands.Count == 0)
                restorePreferences = true; // Mac restarted. Restore choices without enabling capture.
            state = next;
            if (next == null) { StopStream(); RestoreDefaults(); status = "Обновите AudioBridge на Mac"; return; }
            if (commands.Count > 0 && commands.Peek().Command.Id == next.CommandId) commands.Dequeue();
            try {
                if (!restorePreferences && !string.IsNullOrEmpty(next.OutputId)) {
                    preferences = new MicPreferences(next.Source, next.OutputId);
                    var text = JsonSerializer.Serialize(preferences);
                    if (!File.Exists(preferencesPath) || File.ReadAllText(preferencesPath) != text) {
                        Directory.CreateDirectory(Startup.Folder); File.WriteAllText(preferencesPath, text);
                    }
                }
            } catch { }
            if (!next.Enabled) { StopStream(); RestoreDefaults(); status = next.Status; return; }
            if (commands.Count > 0) { StopStream(); return; }
            string current = address + ":" + next.Source + ":" + next.OutputId + ":" + next.Revision;
            if (signature == current && streamTask is { IsCompleted: false }) return;
            StopStream(); signature = current;
            var cancel = new CancellationTokenSource(); streamCancel = cancel;
            var previousTask = streamTask;
            streamTask = Task.Run(async () => {
                try {
                    if (previousTask != null) try { await previousTask; } catch { }
                    cancel.Token.ThrowIfCancellationRequested();
                    await Receive(address, next.OutputId, current, cancel.Token);
                } catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
                finally { cancel.Dispose(); }
            });
        }
    }
    public void LostContact()
    {
        lock (sync) {
            if (Environment.TickCount64 - lastContact > 5000) { StopStream(); RestoreDefaults(); state = null; status = "Нет связи с Mac, микрофон выключен"; }
        }
    }
    void StopStream() { try { streamCancel?.Cancel(); } catch (ObjectDisposedException) { } streamCancel = null; signature = ""; }
    void SetStatus(string text, string expected) { lock (sync) { if (signature == expected) status = text; } }
    async Task Receive(IPAddress address, string outputId, string expected, CancellationToken ct)
    {
        try {
            string streamId = Guid.NewGuid().ToString("N"), nonce = Guid.NewGuid().ToString("N");
            byte[] body = JsonSerializer.SerializeToUtf8Bytes(new { ClientId = clientId, Session = session, Stream = streamId });
            using var request = new HttpRequestMessage(HttpMethod.Post, new UriBuilder("http", address.ToString(), 8765, "/api/microphone").Uri);
            request.Content = new ByteArrayContent(body);
            request.Headers.Add("X-AB-Nonce", nonce);
            request.Headers.Add("X-AB-Auth", UpdateProtocol.RequestMac(key, "POST", "/api/microphone", nonce, body));
            using var headersTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct); headersTimeout.CancelAfter(8000);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, headersTimeout.Token);
            response.EnsureSuccessStatusCode();
            if (!response.Headers.TryGetValues("X-AB-Auth", out var tags) || !UpdateProtocol.Equal(tags.Single(), UpdateProtocol.ResponseMac(key, 200, nonce, [])))
                throw new CryptographicException("Неверная подпись потока микрофона");
            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            byte[] streamKey = MicProtocol.Key(key, streamId);
            using var devices = new MMDeviceEnumerator();
            using var device = devices.GetDevice(outputId);
            if (!device.FriendlyName.Contains("Virtual Mic for AudioRelay", StringComparison.OrdinalIgnoreCase) || device.DataFlow != DataFlow.Capture)
                throw new InvalidOperationException("Не найден Virtual Mic for AudioRelay");
            AudioRelayMicrophone? sink = null;
            ulong sequence = 0;
            int sampleRate = 0;
            byte[] prefix = new byte[2];
            using var cancelPlayback = ct.Register(() => { sink?.Stop(); });
            try {
            while (!ct.IsCancellationRequested) {
                using var frameTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                frameTimeout.CancelAfter(sink == null ? 60000 : 5000); // Allow the first macOS permission prompt.
                await stream.ReadExactlyAsync(prefix, frameTimeout.Token);
                int length = BinaryPrimitives.ReadUInt16LittleEndian(prefix);
                if (length is < 34 or > 992) throw new IOException("Invalid microphone packet size");
                byte[] packet = new byte[length]; await stream.ReadExactlyAsync(packet, frameTimeout.Token);
                var decoded = MicProtocol.Decode(packet, streamKey, sequence++);
                if (sink == null) {
                    sampleRate = decoded.Rate;
                    lock (sync) {
                        ct.ThrowIfCancellationRequested();
                        if (signature != expected) return;
                        sink = new AudioRelayMicrophone(device, sampleRate);
                        activeSink = sink; activeInput = outputId; receivedFrames = 0;
                        DefaultLease.Acquire(outputId);
                        status = "Микрофон Mac подключён к Windows через AudioRelay";
                    }
                }
                if (sampleRate != decoded.Rate) throw new IOException("Microphone sample rate changed");
                sink.Add(decoded.Pcm);
                lock (sync) { if (signature == expected) receivedFrames += decoded.Pcm.Length / 2; }
            }
            } finally {
                lock (sync) { if (activeSink == sink) { activeSink = null; activeInput = ""; } }
                sink?.Dispose();
            }
        }

        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (HttpRequestException) { SetStatus("Переподключение микрофона…", expected); }
        catch (IOException) { SetStatus("Переподключение микрофона…", expected); }
        catch (OperationCanceledException) { SetStatus("Ожидание микрофона на Mac…", expected); }
        catch (Exception e) { SetStatus("Ошибка: " + e.Message, expected); Program.Log("Микрофон: " + e.Message); }
    }
    public void Dispose()
    {
        Task? task;
        lock (sync) { disposed = true; StopStream(); RestoreDefaults(); task = streamTask; }
        try { task?.Wait(2000); } catch { }
        http.Dispose(); streamCancel?.Dispose();
    }
}
