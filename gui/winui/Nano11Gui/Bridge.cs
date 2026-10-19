using System;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Nano11Gui;

// The line protocol with gui\Nano11WinUiHost.ps1: one UTF-8 JSON object per line.
// Requests are { id, op, lang, args }; each reply carries the same id and ok, Kind, Title, Text, Data.
// One request at a time: the builder serves them in order on a single thread.
public sealed class Bridge
{
    private readonly StreamReader? _in;
    private readonly StreamWriter? _out;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private int _nextId;

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
            var obj = JsonNode.Parse(line)?.AsObject();
            if (obj != null && (string?)obj["Op"] == "init") return obj;
        }
    }

    public async Task<JsonObject> RequestAsync(string op, string lang, JsonNode? args = null)
    {
        if (_in == null || _out == null)
        {
            return new JsonObject { ["ok"] = false, ["Kind"] = "Warning", ["Text"] = "Not connected to nano11builder.ps1 (standalone preview)." };
        }
        await _lock.WaitAsync();
        try
        {
            int id = Interlocked.Increment(ref _nextId);
            var msg = new JsonObject { ["id"] = id, ["op"] = op, ["lang"] = lang, ["args"] = args };
            await _out.WriteLineAsync(msg.ToJsonString());
            while (true)
            {
                string? line = await _in.ReadLineAsync();
                if (line == null)
                {
                    return new JsonObject { ["ok"] = false, ["Kind"] = "Error", ["Text"] = "The connection to nano11builder.ps1 was closed." };
                }
                if (!line.TrimStart().StartsWith('{')) continue;
                var reply = JsonNode.Parse(line)?.AsObject();
                if (reply != null && (int?)reply["id"] == id) return reply;
            }
        }
        finally
        {
            _lock.Release();
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
