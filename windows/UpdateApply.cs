using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;

record UpdatePlan(string Target, string Stage, string Digest, string Version, int ParentPid, string HealthToken);

static class UpdateApply
{
    public static string StagePackage(byte[] zipBytes, string expectedHash, string target, string version)
    {
        if (!UpdateProtocol.Equal(UpdateProtocol.Hash(zipBytes), expectedHash)) throw new IOException("Архив обновления повреждён");
        string stage = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(target))!, "updates", Guid.NewGuid().ToString("N"));
        using var zip = new ZipArchive(new MemoryStream(zipBytes), ZipArchiveMode.Read);
        if (zip.Entries.Count > 32) throw new IOException("Too many package entries");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries)
            if (entry.FullName.IndexOfAny(['/', '\\', ':']) >= 0 || entry.FullName is "." or ".." || !names.Add(entry.FullName))
                throw new IOException("Unsafe or duplicate package path");
        var exe = zip.GetEntry("WindowsAudio.exe") ?? throw new IOException("В архиве нет WindowsAudio.exe");
        if (exe.Length is < 1024 or > 140L * 1024 * 1024) throw new IOException("Invalid executable size");
        Directory.CreateDirectory(stage);
        string stagedExe = Path.Combine(stage, "WindowsAudio.new.exe");
        using (var input = exe.Open())
        using (var output = File.Create(stagedExe)) { input.CopyTo(output); if (output.Length != exe.Length) throw new IOException("Truncated executable"); }
        using (var file = File.OpenRead(stagedExe))
            if (file.ReadByte() != 'M' || file.ReadByte() != 'Z') throw new IOException("Invalid Windows executable");
        if (OperatingSystem.IsWindows()) {
            var info = FileVersionInfo.GetVersionInfo(stagedExe);
            var binaryVersion = new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart);
            if (binaryVersion != Version.Parse(version)) throw new IOException("Версия программы в архиве не совпадает с описанием обновления");
        }
        string digest = UpdateProtocol.Hash(File.ReadAllBytes(stagedExe));
        var plan = new UpdatePlan(Path.GetFullPath(target), stage, digest, version, Environment.ProcessId, Guid.NewGuid().ToString("N"));
        File.WriteAllText(Path.Combine(stage, "plan.json"), JsonSerializer.Serialize(plan));
        return stage;
    }
    public static void LaunchHelper(string stage)
    {
        string helper = Path.Combine(stage, "Updater.exe");
        File.Copy(Environment.ProcessPath!, helper, true);
        var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = stage };
        start.ArgumentList.Add("--apply-update"); start.ArgumentList.Add(Path.Combine(stage, "plan.json"));
        _ = Process.Start(start) ?? throw new IOException("Не удалось запустить помощник обновления");
    }
    // Keep the previous binary until the new process confirms that its tray/message loop has started.
    public static void ReplaceWithRollback(string target, string replacement, Func<bool> startAndCheck, Action restartPrevious)
    {
        string backup = target + ".previous";
        bool replaced = false;
        try {
            File.Copy(target, backup, true);
            File.Move(replacement, target, true); replaced = true;
            if (!startAndCheck()) throw new IOException("Новая версия не подтвердила запуск");
        } catch {
            if (replaced) File.Copy(backup, target, true);
            restartPrevious();
            throw;
        }
    }
    public static int Run(string planPath)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        UpdatePlan? plan = null;
        string? resultPath = null;
        try {
            plan = JsonSerializer.Deserialize<UpdatePlan>(File.ReadAllText(planPath))!;
            string stage = Path.GetFullPath(plan.Stage), target = Path.GetFullPath(plan.Target);
            string root = Path.GetDirectoryName(target)!;
            if (!Path.GetFileName(target).Equals("WindowsAudio.exe", StringComparison.OrdinalIgnoreCase) ||
                !stage.StartsWith(Path.Combine(root, "updates") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                !Path.GetDirectoryName(Path.GetFullPath(planPath))!.Equals(stage, StringComparison.OrdinalIgnoreCase) ||
                !Path.GetDirectoryName(Environment.ProcessPath!)!.Equals(stage, StringComparison.OrdinalIgnoreCase)) throw new IOException("Invalid update paths");
            string replacement = Path.Combine(stage, "WindowsAudio.new.exe");
            if (!UpdateProtocol.Equal(UpdateProtocol.Hash(File.ReadAllBytes(replacement)), plan.Digest)) throw new IOException("Staged executable changed");
            resultPath = Path.Combine(root, "update-result.json");
            try {
                using var parent = Process.GetProcessById(plan.ParentPid);
                if (!Path.GetFullPath(parent.MainModule!.FileName).Equals(target, StringComparison.OrdinalIgnoreCase)) throw new IOException("Parent process identity changed");
                if (!parent.WaitForExit(30000)) throw new IOException("Отправитель не завершился; обновление отменено");
            } catch (ArgumentException) { /* Parent already exited. */ }
            string health = Path.Combine(stage, "health.txt");
            Process? launched = null;
            try {
                ReplaceWithRollback(target, replacement, () => {
                    var start = new ProcessStartInfo(target) { UseShellExecute = false, WorkingDirectory = root };
                    start.ArgumentList.Add("--background"); start.ArgumentList.Add("--health-file"); start.ArgumentList.Add(health);
                    start.ArgumentList.Add("--health-token"); start.ArgumentList.Add(plan.HealthToken);
                    bool healthy = false;
                    try {
                        launched = Process.Start(start);
                        for (int i = 0; i < 150; i++) {
                            if (launched == null || launched.HasExited) break;
                            if (File.Exists(health) && File.ReadAllText(health) == plan.HealthToken) { healthy = true; return true; }
                            Thread.Sleep(100);
                        }
                        return false;
                    } finally {
                        if (!healthy && launched != null && !launched.HasExited) { launched.Kill(); launched.WaitForExit(5000); }
                    }
                }, () => {
                    File.WriteAllText(resultPath, JsonSerializer.Serialize(new { Success = false, Message = "Обновление не запустилось; восстановлена предыдущая версия." }));
                    Process.Start(new ProcessStartInfo(target, "--background") { UseShellExecute = false, WorkingDirectory = root });
                });
                File.WriteAllText(resultPath, JsonSerializer.Serialize(new { Success = true, Message = "Обновлено до " + plan.Version }));
            } finally { launched?.Dispose(); }
            return 0;
        } catch (Exception e) {
            if (resultPath != null) try { File.WriteAllText(resultPath, JsonSerializer.Serialize(new { Success = false, Message = e.Message })); } catch { }
            return 1;
        }
    }
}
