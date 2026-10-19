using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

namespace Nano11Gui;

public sealed record TweakDef(string Key, string Category, bool Default, string Description, string DescriptionJa);
public sealed record ComponentDef(string Key, string Text, string Description, bool Default, string Tab, int Order);
public sealed record PresetDef(string Key, Dictionary<string, bool> Components, Dictionary<string, bool> Tweaks, string PayloadFormat);

// The init message of gui\Nano11WinUiHost.ps1 (New-Nano11WinUiInitMessage)
public sealed class InitData
{
    public string Language { get; }
    public List<string> Languages { get; }
    public string StringsDir { get; }
    public List<TweakDef> Tweaks { get; } = new();
    public List<ComponentDef> Components { get; } = new();
    public List<PresetDef> Presets { get; } = new();
    public List<string> PresetNames { get; }
    public List<string> DebloatStandard { get; }
    public List<string> DebloatExperimental { get; }
    public JsonObject Initial { get; }
    public string DefaultWorkDir { get; }
    public string DefaultMigrationRoot { get; }
    public List<string> Sources { get; }
    public JsonObject Extensions { get; }

    public InitData(JsonObject o)
    {
        Language = Str(o["Language"], "en");
        Languages = StrList(o["Languages"]);
        if (Languages.Count == 0) Languages = new List<string> { "en", "ja" };
        StringsDir = Str(o["StringsDir"]);
        foreach (var t in Arr(o["Tweaks"]))
        {
            Tweaks.Add(new TweakDef(Str(t?["Key"]), Str(t?["Category"]), Bool(t?["Default"]), Str(t?["Description"]), Str(t?["DescriptionJa"])));
        }
        foreach (var c in Arr(o["Components"]))
        {
            Components.Add(new ComponentDef(Str(c?["Key"]), Str(c?["Text"]), Str(c?["Description"]), Bool(c?["Default"]), Str(c?["Tab"]), (int?)c?["Order"] ?? 0));
        }
        foreach (var p in Arr(o["Presets"]))
        {
            Presets.Add(new PresetDef(Str(p?["Key"]), BoolMap(p?["Components"]), BoolMap(p?["Tweaks"]), Str(p?["PayloadFormat"], "WIM")));
        }
        PresetNames = StrList(o["PresetNames"]);
        if (PresetNames.Count == 0) PresetNames = Presets.Select(p => p.Key).ToList();
        DebloatStandard = StrList(o["DebloatStandard"]);
        DebloatExperimental = StrList(o["DebloatExperimental"]);
        Initial = o["Initial"] as JsonObject ?? new JsonObject();
        DefaultWorkDir = Str(o["DefaultWorkDir"]);
        DefaultMigrationRoot = Str(o["DefaultMigrationRoot"]);
        Sources = StrList(o["Sources"]);
        Extensions = o["Extensions"] as JsonObject ?? new JsonObject();
    }

    // PowerShell's ConvertTo-Json writes a one-element array as the element and $null as null
    public static IEnumerable<JsonNode?> Arr(JsonNode? n)
    {
        if (n is JsonArray a) return a;
        if (n == null) return Array.Empty<JsonNode?>();
        return new[] { n };
    }

    public static string Str(JsonNode? n, string fallback = "")
    {
        if (n is JsonValue v)
        {
            if (v.TryGetValue(out string? s)) return s ?? fallback;
            return v.ToJsonString();
        }
        return fallback;
    }

    public static bool Bool(JsonNode? n)
    {
        if (n is JsonValue v)
        {
            if (v.TryGetValue(out bool b)) return b;
            if (v.TryGetValue(out string? s)) return string.Equals(s, "true", StringComparison.OrdinalIgnoreCase);
            if (v.TryGetValue(out int i)) return i != 0;
        }
        return false;
    }

    public static List<string> StrList(JsonNode? n) => Arr(n).Select(x => Str(x)).Where(s => s.Length > 0).ToList();

    public static Dictionary<string, bool> BoolMap(JsonNode? n)
    {
        var d = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        if (n is JsonObject o) foreach (var kv in o) d[kv.Key] = Bool(kv.Value);
        return d;
    }
}

// config\ui-strings\<lang>.json. Fallback: that language -> English -> the default -> the key (as Get-Nano11UiString).
public sealed class UiStrings
{
    private readonly Dictionary<string, Dictionary<string, string>> _tables = new();
    private readonly string _dir;
    public string Language { get; set; }

    public UiStrings(string dir, string language)
    {
        _dir = dir;
        Language = language;
    }

    private Dictionary<string, string> Table(string lang)
    {
        if (_tables.TryGetValue(lang, out var t)) return t;
        t = new Dictionary<string, string>();
        try
        {
            string file = Path.Combine(_dir, lang + ".json");
            if (File.Exists(file) && JsonNode.Parse(File.ReadAllText(file)) is JsonObject o)
            {
                foreach (var kv in o) t[kv.Key] = InitData.Str(kv.Value);
            }
        }
        catch
        {
            // A broken table falls back to English / the key, as in the WinForms window
        }
        _tables[lang] = t;
        return t;
    }

    public bool Has(string key) => Table(Language).ContainsKey(key) || Table("en").ContainsKey(key);

    public string Get(string key, string? fallback = null, string? language = null)
    {
        string lang = language ?? Language;
        if (Table(lang).TryGetValue(key, out var s)) return s;
        if (lang != "en" && Table("en").TryGetValue(key, out s)) return s;
        return fallback ?? key;
    }

    public string Format(string key, params object?[] args)
    {
        string text = Get(key);
        try { return string.Format(text, args); } catch (FormatException) { return text; }
    }
}
