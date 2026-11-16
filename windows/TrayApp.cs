#if WINDOWS
using System.Drawing;
using System.Windows.Forms;

sealed class TrayApp : ApplicationContext
{
    readonly NotifyIcon icon;
    readonly ContextMenuStrip menu = new();
    readonly ToolStripMenuItem status = new("Ожидание Mac") { Enabled = false };
    readonly ToolStripMenuItem update = new("Проверить обновление");
    readonly ToolStripMenuItem pause = new("Приостановить звук");
    readonly ToolStripMenuItem micToggle = new("Включить микрофон Mac");
    readonly ToolStripMenuItem micSources = new("Источник микрофона");
    readonly ToolStripMenuItem micStatus = new("Микрофон выключен") { Enabled = false };
    string micMenuKey = "";
    readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    readonly UpdateClient updater;
    readonly CancellationTokenSource lifetime;
    readonly Control dispatcher = new();
    string shownMessage = "";

    public TrayApp(UpdateClient updater, CancellationTokenSource lifetime, string[] args)
    {
        this.updater = updater; this.lifetime = lifetime;
        dispatcher.CreateControl(); _ = dispatcher.Handle;
        var appIcon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? (Icon)SystemIcons.Application.Clone();
        icon = new NotifyIcon { Icon = appIcon, Visible = true, Text = "AudioBridge " + UpdateProtocol.Version, ContextMenuStrip = menu };
        menu.Items.Add("AudioBridge " + UpdateProtocol.Version).Enabled = false;
        menu.Items.Add(status); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(pause); menu.Items.Add(update);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(micToggle); menu.Items.Add(micSources); menu.Items.Add(micStatus);
        menu.Items.Add(new ToolStripSeparator());
        micToggle.Click += (_, _) => updater.Microphone.Queue(enabled: !(updater.Microphone.State?.Enabled ?? false));
        menu.Items.Add("Отключить автозапуск", null, (_, _) => { Startup.Disable(); icon.ShowBalloonTip(3000, "AudioBridge", "Автозапуск отключён. Текущая передача продолжается.", ToolTipIcon.Info); });
        menu.Items.Add("Открыть журнал", null, (_, _) => {
            string path = Path.Combine(Startup.Folder, "status.log");
            if (File.Exists(path)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Выход", null, (_, _) => ExitThread());
        pause.Click += (_, _) => { Program.Paused = !Program.Paused; pause.Text = Program.Paused ? "Возобновить звук" : "Приостановить звук"; };
        update.Click += (_, _) => { updater.RequestUpdate(); icon.ShowBalloonTip(2500, "AudioBridge", "Проверяю обновление на вашем Mac…", ToolTipIcon.Info); };
        icon.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) menu.Show(Cursor.Position); };
        updater.RestartReady = () => dispatcher.BeginInvoke(new Action(ExitThread));
        timer.Tick += (_, _) => {
            RefreshMicrophone();
            status.Text = updater.State;
            update.Enabled = !updater.Busy;
            icon.Text = ("AudioBridge: " + updater.State)[..Math.Min(63, ("AudioBridge: " + updater.State).Length)];
            status.ToolTipText = updater.Message;
            if (updater.Message.Length > 0 && updater.Message != shownMessage) {
                shownMessage = updater.Message;
                icon.ShowBalloonTip(4000, "AudioBridge", updater.Message[..Math.Min(500, updater.Message.Length)], ToolTipIcon.Info);
            }
        };
        timer.Start();
        RefreshMicrophone();
        int i = Array.IndexOf(args, "--health-file"), t = Array.IndexOf(args, "--health-token");
        if (i >= 0 && t >= 0 && args.Length > i + 1 && args.Length > t + 1)
            dispatcher.BeginInvoke(new Action(() => File.WriteAllText(args[i + 1], args[t + 1])));
    }
    void RefreshMicrophone()
    {
        var mic = updater.Microphone; var state = mic.State;
        micToggle.Text = state?.Enabled == true ? "Выключить микрофон Mac" : "Включить микрофон Mac";
        micToggle.Checked = state?.Enabled == true;
        micToggle.Enabled = state != null;
        micStatus.Text = mic.Status.Length > 75 ? mic.Status[..72] + "…" : mic.Status;
        micStatus.ToolTipText = mic.Status;
        var sources = state?.Sources ?? [];
        string key = System.Text.Json.JsonSerializer.Serialize(new { sources, state?.Source });
        if (key == micMenuKey) return;
        micMenuKey = key;
        micSources.DropDownItems.Clear();
        foreach (var source in sources) {
            var item = new ToolStripMenuItem(source.Name) { Checked = source.Id == state?.Source, Enabled = source.Available };
            item.Click += (_, _) => mic.Queue(source: source.Id);
            micSources.DropDownItems.Add(item);
        }
        if (sources.Length == 0) micSources.DropDownItems.Add("Ожидание Mac").Enabled = false;

    }
    protected override void ExitThreadCore()
    {
        timer.Stop(); updater.RestartReady = null; updater.Stop(); lifetime.Cancel();
        icon.Visible = false; icon.Icon?.Dispose(); icon.Dispose(); menu.Dispose(); timer.Dispose(); dispatcher.Dispose();
        base.ExitThreadCore();
    }
}
#endif
