using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text;
using System.Runtime.InteropServices.ComTypes;
using Microsoft.Win32;

static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Entry = "AudioBridge";
    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AudioBridge");
    [DllImport("kernel32.dll")] static extern bool AllocConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint processId);
    public static void OpenConsole()
    {
        if (OperatingSystem.IsWindows() && !AttachConsole(uint.MaxValue)) AllocConsole();
    }
    public static void StopMatchingSenders(string pairingKey)
    {
        foreach (var process in Process.GetProcessesByName("WindowsAudio"))
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId) continue;
                try
                {
                    var executable = process.MainModule?.FileName;
                    if (executable == null) continue;
                    var path = Path.Combine(Path.GetDirectoryName(executable)!, "connection.json");
                    var other = JsonSerializer.Deserialize<Config>(File.ReadAllText(path));
                    if (other?.Key != pairingKey) continue;
                    process.Kill(); process.WaitForExit(5000);
                }
                catch (Exception e) { Program.Log("Не удалось остановить старую копию: " + e.Message); }
            }
        }
    }
    public static void Install(Config config, string configPath)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Installation requires Windows.");
        var executable = Environment.ProcessPath!;
        var destination = Path.Combine(Folder, "WindowsAudio.exe");
        StopMatchingSenders(config.Key);
        Directory.CreateDirectory(Folder);
        if (!Path.GetFullPath(executable).Equals(destination, StringComparison.OrdinalIgnoreCase))
        {
            string staging = destination + ".installing";
            File.Copy(executable, staging, true);
            File.Move(staging, destination, true);
        }
        var configDestination = Path.Combine(Folder, "connection.json");
        if (!Path.GetFullPath(configPath).Equals(configDestination, StringComparison.OrdinalIgnoreCase))
            File.Copy(configPath, configDestination, true);
        foreach (var name in new[] { "NAudio-LICENSE.txt", "dotnet-LICENSE.TXT", "dotnet-THIRD-PARTY-NOTICES.TXT", "README.txt" })
        {
            string source = Path.Combine(AppContext.BaseDirectory, name), target = Path.Combine(Folder, name);
            if (File.Exists(source) && !Path.GetFullPath(source).Equals(target, StringComparison.OrdinalIgnoreCase)) File.Copy(source, target, true);
        }
        using (var key = Registry.CurrentUser.CreateSubKey(RunKey)) key.SetValue(Entry, $"\"{destination}\" --background", RegistryValueKind.String);
        // Do not alter StartupApproved: Task Manager's existing disabled state belongs to the user.
        var programs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "AudioBridge");
        try {
            Directory.CreateDirectory(programs);
            // ASCII file names also support older Windows Shell/locale combinations.
            foreach (var entry in new[] { ("AudioBridge.lnk", "--background"), ("AudioBridge - Stop.lnk", "--stop"), ("AudioBridge - Disable startup.lnk", "--disable-startup") })
            {
                try { WriteShortcut(Path.Combine(programs, entry.Item1), destination, entry.Item2); }
                catch (Exception e) { Program.Log("Программа установлена; не удалось создать необязательный ярлык: " + e.Message); }
            }
        } catch (Exception e) { Program.Log("Программа установлена; меню Пуск недоступно: " + e.Message); }
        Process.Start(new ProcessStartInfo(destination, "--background") { UseShellExecute = true, WorkingDirectory = Folder });
        Program.Log("Установлено в " + Folder);
        Program.Log("Автозагрузка: Диспетчер задач → Автозагрузка приложений → AudioBridge.");
        Program.Log("Остановить сейчас: Процессы/Подробности → WindowsAudio.exe → Снять задачу.");
        Program.Log("Повторный запуск: Пуск → AudioBridge. Если автозагрузка была отключена ранее, включите её вручную в Диспетчере задач.");
    }
    static void WriteShortcut(string path, string executable, string arguments)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        var link = (IShellLinkW)new ShellLink();
        try {
            link.SetPath(executable); link.SetArguments(arguments);
            link.SetWorkingDirectory(Folder); link.SetDescription("AudioBridge - Windows to Mac audio");
            ((IPersistFile)link).Save(path, true);
        } finally { Marshal.FinalReleaseComObject(link); }
    }
    public static void Disable()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, true);
        key?.DeleteValue(Entry, false);
        Program.Log("Автозапуск AudioBridge отключён. Текущий процесс можно остановить в Диспетчере задач.");
    }
}

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
class ShellLink { }
[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int count, IntPtr data, uint flags);
    void GetIDList(out IntPtr id); void SetIDList(IntPtr id);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder text, int count);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string text);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int count);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int count);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
    void GetHotkey(out short key); void SetHotkey(short key);
    void GetShowCmd(out int cmd); void SetShowCmd(int cmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, out int index);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
    void Resolve(IntPtr window, uint flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
}
