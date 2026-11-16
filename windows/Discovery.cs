using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;

static class DiscoveryProtocol
{
    public const int Port = 49153;
    public static byte[] Request(byte[] key, byte[] nonce)
    {
        if (nonce.Length != 16) throw new ArgumentException("Invalid nonce");
        byte[] request = new byte[52];
        "WAD1"u8.CopyTo(request); nonce.CopyTo(request, 4);
        HMACSHA256.HashData(key, request.AsSpan(0, 20)).CopyTo(request, 20);
        return request;
    }
    public static int? VerifyResponse(byte[] key, byte[] nonce, byte[] response)
    {
        if (response.Length != 54 || !response.AsSpan(0, 4).SequenceEqual("WAR1"u8) ||
            !CryptographicOperations.FixedTimeEquals(nonce, response.AsSpan(4, 16)) ||
            !CryptographicOperations.FixedTimeEquals(HMACSHA256.HashData(key, response.AsSpan(0, 22)), response.AsSpan(22))) return null;
        int port = BinaryPrimitives.ReadUInt16LittleEndian(response.AsSpan(20, 2));
        return port > 0 ? port : null;
    }
}

sealed class ReceiverFinder : IDisposable
{
    readonly byte[] key;
    readonly string hint;
    readonly CancellationTokenSource cancellation = new();
    readonly Task worker;
    readonly object sync = new();
    IPEndPoint? current;
    long lastResponse;
    public IPEndPoint? Current
    {
        get { lock (sync) return Environment.TickCount64 - lastResponse < 8000 ? current : null; }
    }
    public ReceiverFinder(Config config)
    {
        key = Convert.FromBase64String(config.Key); hint = config.MacIP;
        worker = Task.Run(Search);
    }
    IEnumerable<IPAddress> Targets()
    {
        var targets = new HashSet<IPAddress> { IPAddress.Broadcast };
        if (IPAddress.TryParse(hint, out var address) && address.AddressFamily == AddressFamily.InterNetwork) targets.Add(address);
        lock (sync) { if (current != null) targets.Add(current.Address); }
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork || unicast.IPv4Mask == null) continue;
                var ip = unicast.Address.GetAddressBytes(); var mask = unicast.IPv4Mask.GetAddressBytes();
                if (mask.All(b => b == 255) || mask.All(b => b == 0)) continue;
                targets.Add(new IPAddress(ip.Select((b, i) => (byte)(b | (byte)~mask[i])).ToArray()));
            }
        }
        return targets;
    }
    async Task Search()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                using var udp = new UdpClient(new IPEndPoint(IPAddress.Any, 0));
                udp.EnableBroadcast = true;
                while (!cancellation.IsCancellationRequested)
                {
                    var nonce = RandomNumberGenerator.GetBytes(16);
                    var request = DiscoveryProtocol.Request(key, nonce);
                    foreach (var target in Targets())
                    {
                        try { await udp.SendAsync(request, new IPEndPoint(target, DiscoveryProtocol.Port), cancellation.Token); }
                        catch (SocketException) { /* Interface might have disappeared during a Wi-Fi change. */ }
                    }
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
                    timeout.CancelAfter(1200);
                    try
                    {
                        while (true)
                        {
                            var reply = await udp.ReceiveAsync(timeout.Token);
                            int? port = DiscoveryProtocol.VerifyResponse(key, nonce, reply.Buffer);
                            if (port == null) continue;
                            lock (sync) {
                                current = new IPEndPoint(reply.RemoteEndPoint.Address, port.Value);
                                lastResponse = Environment.TickCount64;
                            }
                        }
                    }
                    catch (OperationCanceledException) when (!cancellation.IsCancellationRequested) { }
                    await Task.Delay(800, cancellation.Token);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e) { Program.Log("Поиск Mac: " + e.Message); }
            try { await Task.Delay(2000, cancellation.Token); } catch (OperationCanceledException) { return; }
        }
    }
    public void Dispose()
    {
        cancellation.Cancel();
        try { worker.Wait(3000); } catch (AggregateException) { }
        cancellation.Dispose();
    }
}
