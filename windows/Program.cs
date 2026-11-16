using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;

record Config(string MacIP, int Port, string Key);

sealed class PacketSender : IDisposable
{
    readonly UdpClient udp = new();
    readonly AesGcm aes;
    readonly ReceiverFinder? finder;
    readonly IPEndPoint fallback;
    readonly byte[] session = RandomNumberGenerator.GetBytes(8);
    readonly object sendLock = new();
    uint sequence;
    public long Packets { get; private set; }
    public PacketSender(Config config, ReceiverFinder? finder = null)
    {
        aes = new AesGcm(Convert.FromBase64String(config.Key), 16);
        this.finder = finder;
        fallback = new IPEndPoint(IPAddress.TryParse(config.MacIP, out var ip) ? ip : IPAddress.Loopback, config.Port);
    }
    public byte[] Encode(byte[] pcm, int sampleRate)
    {
        if (pcm.Length == 0 || pcm.Length % 4 != 0 || pcm.Length > 960)
            throw new ArgumentException("Invalid PCM length");
        if (sequence == uint.MaxValue) throw new InvalidOperationException("Restart sender to renew session");
        var packet = new byte[24 + pcm.Length + 16];
        "WAM1"u8.CopyTo(packet);
        session.CopyTo(packet, 4);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12), sequence++);
        BinaryPrimitives.WriteInt32LittleEndian(packet.AsSpan(16), sampleRate);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(20), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(22), (ushort)(pcm.Length / 4));
        aes.Encrypt(packet.AsSpan(4, 12), pcm, packet.AsSpan(24, pcm.Length),
            packet.AsSpan(24 + pcm.Length, 16), packet.AsSpan(0, 24));
        return packet;
    }
    public void Send(byte[] pcm, int sampleRate)
    {
        // AudioTarget tolerates a missed discovery answer or two; audio used to stop 8 s after the
        // last answer, which a busy Mac could cause on its own.
        var destination = finder == null ? fallback : finder.AudioTarget;
        if (destination == null) return;
        lock (sendLock) {
            // One sender lives for the whole process, so a capture restart keeps the session and the
            // Mac continues the stream instead of waiting for the old session to expire.
            var packet = Encode(pcm, sampleRate);
            udp.Send(packet, destination);
            Packets++;
        }
    }
    public void Dispose() { udp.Dispose(); aes.Dispose(); }
}

static class Program
{
    public static volatile bool Paused = false;
    static bool background;
    static readonly object logLock = new();
    public static void Log(string message)
    {
        if (!background) { Console.WriteLine(message); return; }
        lock (logLock) {
            try {
                Directory.CreateDirectory(Startup.Folder);
                string path = Path.Combine(Startup.Folder, "status.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024) File.WriteAllText(path, "");
                File.AppendAllText(path, DateTimeOffset.Now.ToString("O") + " " + message + Environment.NewLine);
            } catch { /* Logging failure must not stop audio. */ }
        }
    }
    static float Sample(byte[] data, int offset, int bits, bool floating)
    {
        float value = floating ? BitConverter.ToSingle(data, offset) : bits switch {
            16 => BinaryPrimitives.ReadInt16LittleEndian(data.AsSpan(offset)) / 32768f,
            24 => ((data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16) << 8 >> 8) / 8388608f,
            32 => BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(offset)) / 2147483648f,
            _ => throw new NotSupportedException("Unsupported audio format")
        };
        return float.IsFinite(value) ? Math.Clamp(value, -1, 1) : 0;
    }
    static void SendAudio(PacketSender sender, WaveFormat format, byte[] data, int count)
    {
        bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat ||
            format is WaveFormatExtensible ex && ex.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        int bits = format.BitsPerSample, channels = format.Channels;
        if ((floating && bits != 32) || (!floating && bits is not (16 or 24 or 32)) || channels is < 1 or > 8)
            throw new NotSupportedException($"Use stereo 16/24/32-bit Windows output. Current format: {format}");
        if (format.Encoding == WaveFormatEncoding.Extensible && format is WaveFormatExtensible ext &&
            ext.SubFormat != new Guid("00000001-0000-0010-8000-00aa00389b71") && !floating)
            throw new NotSupportedException("Unsupported encoded audio; select PCM stereo in Windows sound settings.");
        int bytes = bits / 8, frames = count / format.BlockAlign;
        // Preserve the source sample rate. macOS converts it to the current output rate.
        for (int first = 0; first < frames; first += 240)
        {
            int length = Math.Min(240, frames - first);
            var pcm = new byte[length * 4];
            for (int f = 0; f < length; f++)
            {
                int start = (first + f) * format.BlockAlign;
                float left = Sample(data, start, bits, floating);
                float right = channels == 1 ? left : Sample(data, start + bytes, bits, floating);
                // Shared centre and alternating surround channels; omit the LFE channel.
                if (channels == 4)
                {
                    left = (left + Sample(data, start + 2 * bytes, bits, floating) * 0.5f) / 1.5f;
                    right = (right + Sample(data, start + 3 * bytes, bits, floating) * 0.5f) / 1.5f;
                }
                else if (channels > 2)
                {
                    float centre = Sample(data, start + 2 * bytes, bits, floating) * 0.7071f;
                    left += centre; right += centre;
                    for (int c = 4; c < channels; c++)
                    {
                        float surround = Sample(data, start + c * bytes, bits, floating) * 0.5f;
                        if (c % 2 == 0) left += surround; else right += surround;
                    }
                    float headroom = 1 + 0.7071f + Math.Max(0, (channels - 3) / 2) * 0.5f;
                    left /= headroom; right /= headroom;
                }
                BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(f * 4), (short)(Math.Clamp(left, -1, 1) * 32767));
                BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(f * 4 + 2), (short)(Math.Clamp(right, -1, 1) * 32767));
            }
            sender.Send(pcm, format.SampleRate);
        }
    }
    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--apply-update") return UpdateApply.Run(args[1]);
        bool command = args.Any(a => a is "--install" or "--stop" or "--disable-startup" || a.StartsWith("--test") || a.StartsWith("--verify") || a is "--fixture" or "--discovery-request" or "--find-mac");
        background = !command;
        if (!background) {
            Startup.OpenConsole();
            Console.OutputEncoding = Encoding.UTF8;
        }
        try
        {
            var configPath = args.Length >= 2 && args[0] == "--config" ? args[1] : Path.Combine(AppContext.BaseDirectory, "connection.json");
            var config = JsonSerializer.Deserialize<Config>(File.ReadAllText(configPath))!;
            if (Convert.FromBase64String(config.Key).Length != 32 || config.Port is < 1 or > 65535) throw new ArgumentException("Invalid connection.json");
            if (args.Contains("--test-mic-fixture")) { MicrophoneTests.Fixture(config); return 0; }
            if (args.Contains("--test-mic-defaults")) { MicrophoneTests.Defaults(); return 0; }
            if (args.Contains("--test-mic-http")) { MicrophoneTests.Http(config).GetAwaiter().GetResult(); return 0; }
            if (args.Contains("--test-update-files")) { UpdateTests.Filesystem(); return 0; }
            if (args.Contains("--test-update-http")) { UpdateTests.Http(config).GetAwaiter().GetResult(); return 0; }
            if (args.Contains("--discovery-request")) {
                File.WriteAllBytes("discovery-request.bin", DiscoveryProtocol.Request(Convert.FromBase64String(config.Key), RandomNumberGenerator.GetBytes(16)));
                return 0;
            }
            if (args.Contains("--verify-discovery")) {
                var key = Convert.FromBase64String(config.Key);
                var nonce = File.ReadAllBytes("discovery-request.bin").AsSpan(4, 16).ToArray();
                var response = File.ReadAllBytes("discovery-response.bin");
                if (DiscoveryProtocol.VerifyResponse(key, nonce, response) != config.Port) throw new Exception("Invalid Swift response");
                if (DiscoveryProtocol.VerifyResponse(RandomNumberGenerator.GetBytes(32), nonce, response) != null) throw new Exception("Accepted wrong key");
                if (DiscoveryProtocol.VerifyResponse(key, RandomNumberGenerator.GetBytes(16), response) != null) throw new Exception("Accepted wrong challenge");
                response[20] ^= 1;
                if (DiscoveryProtocol.VerifyResponse(key, nonce, response) != null) throw new Exception("Accepted tampering");
                Log("PASS: discovery C# → Swift → C#, rejects wrong key, replay challenge and tampering"); return 0;
            }
            if (args.Contains("--find-mac")) {
                using var testFinder = new ReceiverFinder(config);
                for (int i = 0; i < 100; i++) {
                    if (testFinder.Current is { } endpoint) { Log("FOUND " + endpoint); return 0; }
                    Thread.Sleep(100);
                }
                throw new Exception("Discovery timed out");
            }
            if (args.Contains("--test-reconnect")) {
                using var testFinder = new ReceiverFinder(config);
                int stage = 0;
                for (int i = 0; i < 280; i++) {
                    var endpoint = testFinder.Current;
                    if (stage == 0 && endpoint != null) { Log("FOUND " + endpoint); stage = 1; }
                    else if (stage == 1 && endpoint == null) { Log("LOST: stale endpoint expired"); stage = 2; }
                    else if (stage == 2 && endpoint != null) { Log("REF0UND " + endpoint); return 0; }
                    Thread.Sleep(100);
                }
                throw new Exception("Reconnect test timed out at stage " + stage);
            }
            if (args.Contains("--fixture"))
            {
                using var fixture = new PacketSender(config);
                byte[] pcm = new byte[16];
                BinaryPrimitives.WriteInt16LittleEndian(pcm, 16384);
                BinaryPrimitives.WriteInt16LittleEndian(pcm.AsSpan(2), -16384);
                File.WriteAllBytes("fixture.bin", fixture.Encode(pcm, 48000));
                return 0;
            }
            if (args.Contains("--test-silence"))
            {
                using var test = new PacketSender(config);
                var clock = System.Diagnostics.Stopwatch.StartNew();
                for (int burst = 0; burst < 40; burst++) {
                    while (clock.ElapsedMilliseconds < burst * 100) Thread.Sleep(1);
                    for (int i = 0; i < 20; i++) test.Send(new byte[960], 48000);
                }
                Console.WriteLine($"Sent {test.Packets} encrypted silent test packets.");
                return 0;
            }
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Audio capture requires Windows 10/11.");
            if (args.Contains("--install")) { Startup.Install(config, configPath); return 0; }
            if (args.Contains("--disable-startup")) { Startup.Disable(); return 0; }
            if (args.Contains("--stop")) { Startup.StopMatchingSenders(config.Key); Log("AudioBridge остановлен."); return 0; }
            string pair = Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(config.Key)))[..16];
            using var singleton = new Mutex(true, @"Local\AudioBridge-" + pair, out bool first);
            if (!first) { Log("AudioBridge уже запущен. Управление доступно в Диспетчере задач."); return 0; }
            using var finder = new ReceiverFinder(config);
            using var lifetime = new CancellationTokenSource();
            using var updater = new UpdateClient(config, finder);
            var captureTask = Task.Run(() => RunCapture(config, finder, lifetime.Token));
#if WINDOWS
            System.Windows.Forms.Application.EnableVisualStyles();
            System.Windows.Forms.Application.SetCompatibleTextRenderingDefault(false);
            System.Windows.Forms.Application.Run(new TrayApp(updater, lifetime, args));
#else
            Log("The tray requires Windows.");
#endif
            lifetime.Cancel();
            captureTask.Wait(5000);
            return 0;
        }
        catch (Exception e)
        {
            Log($"Ошибка: {e.Message}");
            if (!background && !Console.IsInputRedirected) { Console.WriteLine("Нажмите Enter для выхода."); Console.ReadLine(); }
            return 1;
        }
    }
    static void RunCapture(Config config, ReceiverFinder finder, CancellationToken cancellation)
    {
            using var sender = new PacketSender(config, finder);
            int retryMs = 500;
            while (!cancellation.IsCancellationRequested)
            {
                long started = Environment.TickCount64;
                try
                {
                    using var devices = new MMDeviceEnumerator();
                    using var device = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                    string deviceID = device.ID;
                    using var capture = new WasapiLoopbackCapture(device);
                    using var ended = new ManualResetEventSlim();
                    Exception? failure = null;
                    bool boosted = false;
                    capture.DataAvailable += (_, e) => {
                        if (!boosted) {
                            // NAudio's capture thread runs at normal priority; a game or a Discord call
                            // can starve it and turn the stream into bursts the Mac cannot smooth out.
                            try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch { }
                            boosted = true;
                        }
                        if (failure != null || Paused) return;
                        try { SendAudio(sender, capture.WaveFormat, e.Buffer, e.BytesRecorded); }
                        catch (Exception ex) { failure = ex; ended.Set(); }
                    };
                    capture.RecordingStopped += (_, e) => { failure ??= e.Exception; ended.Set(); };
                    Log($"Источник: {device.FriendlyName}");
                    capture.StartRecording();
                    Log($"Формат: {capture.WaveFormat.SampleRate} Hz, {capture.WaveFormat.Channels} канал(а)");
                    int seconds = 0;
                    while (!cancellation.IsCancellationRequested && !ended.Wait(1000))
                    {
                        using var current = devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                        if (current.ID != deviceID) { Log("Устройство вывода изменилось. Переподключение…"); break; }
                        if (++seconds % 5 == 0)
                            Log(finder.Current is { } endpoint ? $"Mac: {endpoint.Address}. Отправлено пакетов: {sender.Packets}." : "Ожидание Mac: откройте AudioBridge на Mac и проверьте общую сеть.");
                    }
                    capture.StopRecording();
                    ended.Wait(2000);
                    if (failure != null) throw failure;
                }
                catch (Exception e)
                {
                    // Device hand-offs (headphones, Bluetooth, an app reconfiguring the endpoint) usually
                    // settle within a second, so retry quickly and back off only if it keeps failing.
                    if (Environment.TickCount64 - started > 10000) retryMs = 500;
                    Log($"Не удалось передать звук: {e.Message}\nПовтор через {retryMs} мс…");
                    for (int waited = 0; waited < retryMs && !cancellation.IsCancellationRequested; waited += 100) Thread.Sleep(100);
                    retryMs = Math.Min(retryMs * 2, 3000);
                }
            }
    }

}
