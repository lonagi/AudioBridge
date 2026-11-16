using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

// Compatibility adapter for the user's installed AudioRelay Virtual Mic 1.0.2 driver.
// Wire contract verified against AudioRelay 0.27.5's native-driver.dll and driver:
// initialize: uint32 queue bytes; write: PCM16 LE / 48 kHz / stereo, response: two uint32s.
// No AudioRelay binaries are copied, installed or redistributed by AudioBridge.
sealed class AudioRelayMicrophone : IDisposable
{
    const string DevicePath = @"\\.\AudioRelayVirtualMicDeviceLink";
    const string SupportedDriver = "AE9C6B8B3B96E2F898D2CFF61B19684C9A30675BD14B642088D221E2855D733B";
    const uint Initialize = 0x223070, Write = 0x223074;
    const int QueueBytes = 19200; // 100 ms, the driver's existing client default.
    readonly object sync = new();
    readonly BufferedWaveProvider buffer;
    readonly IWaveProvider converted;
    readonly WasapiCapture monitor;
    readonly byte[] convertedBytes = new byte[3840];
    bool stopped;
    bool initialized;
    float peak;
    long inputFrames;
    public float TakePeak() { lock (sync) { var result = peak; peak = 0; return result; } }
    public long InputFrames { get { lock (sync) return inputFrames; } }
    public static void CheckDriver()
    {
        string file = Path.Combine(Environment.SystemDirectory, "drivers", "virtual-mic.sys");
        if (!File.Exists(file)) throw new InvalidOperationException("Не установлен Virtual Mic for AudioRelay");
        using var stream = File.OpenRead(file);
        if (Convert.ToHexString(SHA256.HashData(stream)) != SupportedDriver)
            throw new InvalidOperationException("Эта версия драйвера AudioRelay пока не поддерживается. Нужен Virtual Mic 1.0.2 из AudioRelay 0.27.5");
    }
    public AudioRelayMicrophone(MMDevice input, int rate)
    {
        CheckDriver();
        buffer = new BufferedWaveProvider(new WaveFormat(rate, 16, 1)) { ReadFully = false, BufferDuration = TimeSpan.FromMilliseconds(250) };
        ISampleProvider samples = buffer.ToSampleProvider();
        if (rate != 48000) samples = new WdlResamplingSampleProvider(samples, 48000);
        converted = new SampleToWaveProvider16(new MonoToStereoSampleProvider(samples));
        monitor = new WasapiCapture(input, true, 20) { WaveFormat = new WaveFormat(48000, 16, 2) };
        monitor.DataAvailable += (_, e) => {
            float value = 0;
            for (int i = 0; i + 1 < e.BytesRecorded; i += 2)
                value = Math.Max(value, Math.Abs(BinaryPrimitives.ReadInt16LittleEndian(e.Buffer.AsSpan(i))) / 32768f);
            lock (sync) { peak = Math.Max(peak, value); inputFrames += e.BytesRecorded / 4; }
        };
        try {
            ResetQueue(); initialized = true;
            monitor.StartRecording();
        } catch { monitor.Dispose(); throw; }
    }
    static byte[] Control(uint code, byte[] bytes, int count, int responseLength)
    {
        using var device = CreateFile(DevicePath, 0, 0, IntPtr.Zero, 3, 4, IntPtr.Zero);
        if (device.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Не удалось открыть микрофон AudioRelay");
        byte[] result = new byte[responseLength];
        if (!DeviceIoControl(device, code, bytes, count, result, result.Length, out int returned, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Драйвер AudioRelay не принял звук");
        if (returned != responseLength) throw new InvalidOperationException("Неожиданный ответ драйвера AudioRelay");
        return result;
    }
    static void ResetQueue() => Control(Initialize, BitConverter.GetBytes(QueueBytes), 4, 0);
    public void Add(byte[] pcm)
    {
        lock (sync) {
            if (stopped) return;
            buffer.AddSamples(pcm, 0, pcm.Length);
            int count;
            while ((count = converted.Read(convertedBytes, 0, convertedBytes.Length)) > 0) {
                if (count % 4 != 0) throw new InvalidOperationException("Неверный формат микрофона AudioRelay");
                Control(Write, convertedBytes, count, 8);
            }
        }
    }
    public void Stop()
    {
        lock (sync) {
            if (stopped) return;
            stopped = true;
            if (initialized) { try { ResetQueue(); } catch { } }
        }
        try { monitor.StopRecording(); } catch { }
    }
    public void Dispose() { Stop(); monitor.Dispose(); }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize, [Out] byte[] output, int outputSize, out int returned, IntPtr overlapped);
}
