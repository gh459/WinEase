using System;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace WinEaseGui;

// The line protocol with gui\WinEaseWinUiHost.ps1: one UTF-8 JSON object per line.
// Requests are { id, op, lang, args }; each reply carries the same id and ok, Kind, Title, Text, Data.
// One request at a time: the builder serves them in order on a single thread.
public sealed class Bridge
{
    private readonly StreamReader? _in;
    private readonly StreamWriter? _out;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private int _nextId;

    // Hang guard for RequestAsync, not an expected duration: some ops the host
    // serves (backup, restore, estimates) can legitimately run for minutes, so
    // the limit is generous. Without any limit a hung host would hold _lock
    // forever and freeze every later request with no way to recover.
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromMinutes(30);

    public bool IsConnected => _in != null;

    private Bridge(StreamReader? input, StreamWriter? output)
    {
        _in = input;
        _out = output;
    }

    public static Bridge CreateStdio()
    {
        var utf8 = new UTF8Encoding(false);
        var input = new StreamReader(Console.OpenStandardInput(), utf8);
        var output = new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true, NewLine = "\n" };
        return new Bridge(input, output);
    }

    public static Bridge CreateOffline() => new(null, null);

    public async Task<JsonObject?> ReadInitAsync()
    {
        if (_in == null) return null;
        while (true)
        {
            string? line = await _in.ReadLineAsync();
            if (line == null) return null;
            if (!line.TrimStart().StartsWith('{')) continue;
            JsonObject? obj;
            try
            {
                obj = JsonNode.Parse(line)?.AsObject();
            }
            catch (System.Text.Json.JsonException ex)
            {
                // A single malformed line must not abort startup (the same
                // tolerance ListenProgressAsync already has): log the reason
                // through App.LogError and keep reading until the init line.
                App.LogError(ex);
                continue;
            }
            if (obj != null && (string?)obj["Op"] == "init") return obj;
        }
    }

    public async Task<JsonObject> RequestAsync(string op, string lang, JsonNode? args = null)
    {
        if (_in == null || _out == null)
        {
            return new JsonObject { ["ok"] = false, ["Kind"] = "Warning", ["Text"] = "Not connected to WinEasebuilder.ps1 (standalone preview)." };
        }
        await _lock.WaitAsync();
        try
        {
            int id = Interlocked.Increment(ref _nextId);
            var msg = new JsonObject { ["id"] = id, ["op"] = op, ["lang"] = lang, ["args"] = args };
            await _out.WriteLineAsync(msg.ToJsonString());
            using var timeout = new CancellationTokenSource(RequestTimeout);
            while (true)
            {
                string? line;
                try
                {
                    line = await _in.ReadLineAsync(timeout.Token);
                }
                catch (OperationCanceledException)
                {
                    // Synthesize the same shape as the disconnect reply instead
                    // of throwing, so callers show an error and the finally
                    // below releases _lock for later requests. Note: a reply
                    // that still arrives afterwards is left unread, so the
                    // stream may be out of sync from here on.
                    return new JsonObject { ["ok"] = false, ["Kind"] = "Error", ["Text"] = $"Timed out waiting for a reply to '{op}' from WinEasebuilder.ps1 (no reply within {RequestTimeout.TotalMinutes:0} minutes)." };
                }
                if (line == null)
                {
                    return new JsonObject { ["ok"] = false, ["Kind"] = "Error", ["Text"] = "The connection to WinEasebuilder.ps1 was closed." };
                }
                if (!line.TrimStart().StartsWith('{')) continue;
                JsonObject? reply;
                try
                {
                    reply = JsonNode.Parse(line)?.AsObject();
                }
                catch (System.Text.Json.JsonException ex)
                {
                    // Skip a malformed line and keep waiting for our reply,
                    // like ListenProgressAsync does for progress lines.
                    App.LogError(ex);
                    continue;
                }
                if (reply != null && (int?)reply["id"] == id) return reply;
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    // Plugins (lib\WinEasePlugins.ps1): the lock file entries, and the two-step registration of a DLL.
    public Task<JsonObject> PluginsListAsync(string lang) => RequestAsync("plugins.list", lang);

    // Step 1 (confirmSha256 empty): the reply carries Data.Sha256 for the user to confirm.
    // Step 2: send the hash that was shown; the builder copies the DLL to plugins\user and adds it to config\user\plugins.lock.psd1.
    public Task<JsonObject> PluginsAddUserAsync(string lang, string path, string? confirmSha256 = null, string onError = "Warn") =>
        RequestAsync("plugins.addUser", lang, new JsonObject { ["Path"] = path, ["ConfirmSha256"] = confirmSha256 ?? "", ["OnError"] = onError });

    // After the result the builder keeps the pipe open and sends { op: "progress", event: phase|log|done, ... }
    // lines while it builds. Runs until the builder closes the pipe.
    public async Task ListenProgressAsync(Action<JsonObject> onProgress)
    {
        if (_in == null) return;
        while (true)
        {
            string? line = await _in.ReadLineAsync();
            if (line == null) return;
            if (!line.TrimStart().StartsWith('{')) continue;
            try
            {
                var obj = JsonNode.Parse(line)?.AsObject();
                if (obj != null && (string?)obj["op"] == "progress") onProgress(obj);
            }
            catch (System.Text.Json.JsonException ex)
            {
                // Skip a malformed line and log it so JSON parsing errors are not silently ignored.
                App.LogError(ex);
            }
        }
    }

    // The final message; the builder replies and stops listening. Offline it goes to stdout for inspection.
    public async Task SendResultAsync(string lang, JsonObject result)
    {
        if (_out == null)
        {
            Console.WriteLine(result.ToJsonString());
            return;
        }
        await _lock.WaitAsync();
        try
        {
            var msg = new JsonObject { ["id"] = Interlocked.Increment(ref _nextId), ["op"] = "result", ["lang"] = lang, ["args"] = result };
            await _out.WriteLineAsync(msg.ToJsonString());
        }
        finally
        {
            _lock.Release();
        }
    }
}
