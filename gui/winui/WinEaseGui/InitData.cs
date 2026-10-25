using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;

namespace WinEaseGui;

public sealed record TweakDef(string Key, string Category, bool Default, string Description, string DescriptionJa);
public sealed record ComponentDef(string Key, string Text, string Description, bool Default, string Tab, int Order);
// Debloat* = the Advanced Debloat selection the preset itself defines (none of the built-in presets define any);
// "Revert to preset" restores it, switching presets leaves the window's selection alone.
// UseVHDX is applied when a preset is applied, but the state rules do not compare it (docs\GUI_PRESET_STATE.md).
public sealed record PresetDef(string Key, Dictionary<string, bool> Components, Dictionary<string, bool> Tweaks, string PayloadFormat, bool UseVHDX,
    List<string> DebloatStandard, List<string> DebloatExperimental, Dictionary<string, string> DebloatEngines);

// The execution engine of one Advanced Debloat target (config\schema.psd1 -> DebloatEngines)
public sealed record EngineDef(List<string> Engines, string Default);

// The init message of gui\WinEaseWinUiHost.ps1 (New-WinEaseWinUiInitMessage)
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
    public Dictionary<string, EngineDef> DebloatEngines { get; } = new(StringComparer.Ordinal);
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
            var presetEngines = new Dictionary<string, string>(StringComparer.Ordinal);
            if (p?["DebloatEngineSelection"] is JsonObject pe) foreach (var kv in pe) presetEngines[kv.Key] = Str(kv.Value);
            Presets.Add(new PresetDef(Str(p?["Key"]), BoolMap(p?["Components"]), BoolMap(p?["Tweaks"]), Str(p?["PayloadFormat"], "WIM"), Bool(p?["UseVHDX"]),
                StrList(p?["AdvancedDebloatStandard"]), StrList(p?["AdvancedDebloatExperimental"]), presetEngines));
        }
        PresetNames = StrList(o["PresetNames"]);
        if (PresetNames.Count == 0) PresetNames = Presets.Select(p => p.Key).ToList();
        DebloatStandard = StrList(o["DebloatStandard"]);
        DebloatExperimental = StrList(o["DebloatExperimental"]);
        foreach (var kv in (o["DebloatEngines"] as JsonObject) ?? new JsonObject())
        {
            if (kv.Value is not JsonObject def) continue;
            var engines = new List<string>();
            foreach (var e in Arr(def["Engines"])) engines.Add(Str(e));
            DebloatEngines[kv.Key] = new EngineDef(engines, Str(def["Default"]));
        }
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

// config\ui-strings\<lang>.json. Fallback: that language -> English -> the default -> the key (as Get-WinEaseUiString).
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
