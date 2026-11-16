using System.Runtime.InteropServices;
using System.Text.Json;
using NAudio.CoreAudioApi;

interface ICaptureDefaults
{
    string? Get(int role);
    void Set(int role, string id);
}

sealed class WindowsCaptureDefaults : ICaptureDefaults
{
    public string? Get(int role)
    {
        using var devices = new MMDeviceEnumerator();
        try { using var device = devices.GetDefaultAudioEndpoint(DataFlow.Capture, (Role)role); return device.ID; }
        catch (COMException e) when (e.HResult == unchecked((int)0x80070490)) { return null; }
    }
    public void Set(int role, string id)
    {
        object policy = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9"))!)!;
        try { Marshal.ThrowExceptionForHR(((IPolicyConfig)policy).SetDefaultEndpoint(id, role)); }
        finally { Marshal.ReleaseComObject(policy); }
        if (Get(role) != id) throw new IOException("Windows не переключила микрофон по умолчанию");
    }
    // Windows PolicyConfig ABI; preceding slots must remain in this order.
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        void GetMixFormat(); void GetDeviceFormat(); void ResetDeviceFormat(); void SetDeviceFormat();
        void GetProcessingPeriod(); void SetProcessingPeriod(); void GetShareMode(); void SetShareMode();
        void GetPropertyValue(); void SetPropertyValue();
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        void SetEndpointVisibility();
    }
}

// Persist before changing Windows so a subsequent launch can recover after Task Manager / a crash.
sealed class CaptureDefaultLease
{
    record Journal(string Target, Dictionary<int, string?> Previous);
    readonly ICaptureDefaults defaults;
    readonly string path;
    Journal? journal;
    public string Status { get; private set; } = "Не изменён";
    public CaptureDefaultLease(ICaptureDefaults defaults, string path)
    {
        this.defaults = defaults; this.path = path;
        if (File.Exists(path)) {
            journal = JsonSerializer.Deserialize<Journal>(File.ReadAllText(path)) ?? throw new IOException("Не удалось прочитать прежний микрофон Windows");
            Restore();
        }
    }
    public bool IsDefault(string target) => Enumerable.Range(0, 3).All(role => defaults.Get(role) == target);
    public void Acquire(string target)
    {
        if (journal?.Target == target) return; // Do not fight a user's manual change during the session.
        Restore();
        journal = new Journal(target, Enumerable.Range(0, 3).ToDictionary(role => role, defaults.Get));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(journal)); File.Move(temp, path, true);
        try {
            foreach (int role in journal.Previous.Keys) if (defaults.Get(role) != target) defaults.Set(role, target);
            Status = "Микрофон Mac выбран по умолчанию";
        } catch { Restore(); throw; }
    }
    public void Restore()
    {
        if (journal == null) return;
        // Restore only our own changes. A manual selection made afterwards belongs to the user.
        foreach (var item in journal.Previous) {
            if (!string.IsNullOrEmpty(item.Value) && defaults.Get(item.Key) == journal.Target && item.Value != journal.Target)
                defaults.Set(item.Key, item.Value);
        }
        File.Delete(path); journal = null; Status = "Прежний микрофон Windows восстановлен";
    }
}
