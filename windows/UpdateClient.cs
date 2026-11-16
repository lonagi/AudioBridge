using System.Net.Http;
using System.Text.Json;

record UpdateManifest(string Version, string Sha256, long Size, string RequestId, MicSnapshot? Microphone = null);
record UpdateResult(bool Success, string Message);

sealed class UpdateClient : IDisposable
{
    readonly ReceiverFinder finder;
    readonly byte[] key;
    readonly HttpClient http = new(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(90) };
    readonly CancellationTokenSource cancel = new();
    readonly string clientId;
    readonly Task worker;
    int manual;
    string handledRequest = "";
    public string State { get; private set; } = "Ожидание Mac";
    public string Message { get; private set; } = "";
    public bool Busy { get; private set; }
    public Action? RestartReady { get; set; }
    public MicrophoneClient Microphone { get; }
    public UpdateClient(Config config, ReceiverFinder finder)
    {
        this.finder = finder; key = Convert.FromBase64String(config.Key);
        // Stable for this pairing and Windows account; never sent to an external service.
        clientId = UpdateProtocol.Hash(System.Text.Encoding.UTF8.GetBytes(Environment.MachineName + "\n" + Environment.UserName + "\n" + config.Key))[..24];
        Microphone = new MicrophoneClient(key, clientId);
        worker = Task.Run(Loop);
    }
    public void RequestUpdate() => Interlocked.Exchange(ref manual, 1);
    public void Stop() { Microphone.Queue(enabled: false); cancel.Cancel(); }
    UpdateResult? TakeResult()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "update-result.json");
        try {
            if (!File.Exists(path)) return null;
            var result = JsonSerializer.Deserialize<UpdateResult>(File.ReadAllText(path));
            File.Delete(path);
            return result;
        } catch { return null; } // The helper may still be writing; retry on the next poll.
    }
    async Task<UpdateManifest> Report(System.Net.IPAddress address, string state, string message, CancellationToken ct)
    {
        var body = JsonSerializer.SerializeToUtf8Bytes(new { ClientId = clientId, Name = Environment.MachineName, Version = UpdateProtocol.Version, State = state, Message = message, RequestId = handledRequest, Microphone = Microphone.Report() });
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(3000);
        var result = JsonSerializer.Deserialize<UpdateManifest>(await UpdateProtocol.Fetch(http, address, key, "POST", "/api/status", body, timeout.Token))!;
        Microphone.Apply(result.Microphone, address);
        return result;
    }
    async Task Loop()
    {
        while (!cancel.IsCancellationRequested)
        {
            try {
                var endpoint = finder.Current;
                if (endpoint == null) { Microphone.LostContact(); State = "Ожидание Mac"; await Task.Delay(500, cancel.Token); continue; }
                var result = TakeResult();
                if (result != null) { Message = result.Message; Program.Log("Результат обновления: " + Message); }
                var manifest = await Report(endpoint.Address, result is { Success: false } ? "Error" : "Ready", Message, cancel.Token);
                State = "Подключено к Mac";
                bool requested = Interlocked.Exchange(ref manual, 0) != 0;
                bool remote = manifest.RequestId.Length > 0 && manifest.RequestId != handledRequest;
                if (requested || remote) {
                    handledRequest = manifest.RequestId;
                    if (!Version.TryParse(manifest.Version, out var next) || next < Version.Parse(UpdateProtocol.Version))
                        throw new IOException("Предложена недопустимая версия обновления");
                    if (next == Version.Parse(UpdateProtocol.Version)) {
                        Message = "Установлена актуальная версия " + UpdateProtocol.Version;
                        await Report(endpoint.Address, "Current", Message, cancel.Token);
                    } else {
                        Busy = true; State = "Скачивание обновления…";
                        await Report(endpoint.Address, "Downloading", State, cancel.Token);
                        var bytes = await UpdateProtocol.Fetch(http, endpoint.Address, key, "GET", "/api/package", [], cancel.Token);
                        if (bytes.LongLength != manifest.Size) throw new IOException("Размер обновления не совпадает");
                        string stage = UpdateApply.StagePackage(bytes, manifest.Sha256, Environment.ProcessPath!, manifest.Version);
                        State = "Перезапуск отправителя…";
                        await Report(endpoint.Address, "Restarting", State, cancel.Token);
                        cancel.Token.ThrowIfCancellationRequested();
                        UpdateApply.LaunchHelper(stage);
                        RestartReady?.Invoke(); return;
                    }
                }
                await Task.Delay(500, cancel.Token);
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { return; }
            catch (Exception e) {
                Microphone.LostContact();
                Message = e.Message; State = "Обновление недоступно"; Program.Log("Обновление: " + e.Message);
                if (finder.Current is { } endpoint) try { await Report(endpoint.Address, "Error", Message, cancel.Token); } catch { }
                try { await Task.Delay(3000, cancel.Token); } catch (OperationCanceledException) { return; }
            }
            finally { Busy = false; }
        }
    }
    public void Dispose()
    {
        cancel.Cancel();
        try { worker.Wait(3000); } catch { }
        http.Dispose(); cancel.Dispose();
        Microphone.Dispose();
    }
}
