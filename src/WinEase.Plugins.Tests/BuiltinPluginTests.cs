using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using WinEase.Plugins.Builtin.Latency;
using WinEase.Plugins.Builtin.PostInstallTools;
using WinEase.Plugins.Builtin.UpstreamSync;
using Xunit;

namespace WinEase.Plugins.Tests
{
    public class UpstreamSyncTests
    {
        private static readonly string[] Hives = { "zSYSTEM", "zSOFTWARE", "zDEFAULT", "zNTUSER", "zCOMPONENTS" };
        private static readonly string[] Types = { "REG_SZ", "REG_DWORD", "REG_EXPAND_SZ", "REG_BINARY", "REG_QWORD", "REG_MULTI_SZ" };

        [Fact]
        public void IsADataPluginThatAppliesToEveryImage()
        {
            UpstreamSyncPlugin plugin = new UpstreamSyncPlugin();
            Assert.Equal("winease.builtin.upstreamsync", plugin.Id);
            Assert.True(plugin.AppliesTo(new ImageInfo(26100, 0, "Pro", "amd64")));
            Assert.True(plugin.AppliesTo(new ImageInfo(0, 0, "", "")));
            Assert.Empty(plugin.Describe().ReplacesPhases);
            Assert.NotEmpty(plugin.Describe().Tweaks);
        }

        [Fact]
        public void EveryRegistryEntryIsWellFormed()
        {
            foreach (RegistryEntry entry in new UpstreamSyncPlugin().GetRegistryEntries(new ImageInfo(0, 0, "", "")))
            {
                Assert.Contains(entry.Hive, Hives);
                Assert.Contains(entry.Type, Types);
                Assert.False(string.IsNullOrWhiteSpace(entry.Path));
                Assert.False(entry.Path.StartsWith("\\", StringComparison.Ordinal));
                Assert.False(string.IsNullOrWhiteSpace(entry.Tweak));
                // an offline SYSTEM hive has no CurrentControlSet; a key of that name would be created literally (Bug Check 0x67)
                if (entry.Hive == "zSYSTEM") Assert.False(entry.Path.StartsWith("CurrentControlSet", StringComparison.OrdinalIgnoreCase), entry.Path);
            }
        }

        [Fact]
        public void NoValueIsWrittenTwice()
        {
            IList<RegistryEntry> entries = UpstreamSyncPlugin.RegistryData();
            var duplicates = entries.GroupBy(e => new { e.Hive, e.Path, e.Name }).Where(g => g.Count() > 1).Select(g => g.Key).ToList();
            Assert.Empty(duplicates);
        }

        [Fact]
        public void TweakKeysAndDefaultsMatchTheSchema()
        {
            ISet<string> components;
            IDictionary<string, bool> schema = RepoFiles.SchemaSettings(out components);
            foreach (RegistryEntry entry in UpstreamSyncPlugin.RegistryData())
            {
                Assert.True(schema.ContainsKey(entry.Tweak), "unknown tweak " + entry.Tweak);
                Assert.True(schema[entry.Tweak] == entry.Default, entry.Tweak + ": the default of the entry differs from config\\schema.psd1");
            }
            foreach (string key in new UpstreamSyncPlugin().Describe().Tweaks) Assert.True(schema.ContainsKey(key), key);
        }

        [Fact]
        public void AppxRulesNameKnownSettingsAndNeverTheProtectedPackages()
        {
            ISet<string> components;
            IDictionary<string, bool> schema = RepoFiles.SchemaSettings(out components);
            string[] protectedHosts = { "Microsoft.UI.Xaml", "Microsoft.VCLibs", "MicrosoftWindows.Client.CBS", "ShellExperienceHost", "StartMenuExperienceHost", "DesktopAppInstaller", "CoreAI" };
            IList<AppxRemovalRule> rules = UpstreamSyncPlugin.AppxData();
            Assert.NotEmpty(rules);
            foreach (AppxRemovalRule rule in rules)
            {
                Assert.False(string.IsNullOrWhiteSpace(rule.Pattern));
                if (!string.IsNullOrEmpty(rule.Option)) Assert.True(schema.ContainsKey(rule.Option), rule.Option);
                foreach (string protectedName in protectedHosts) Assert.DoesNotContain(protectedName, rule.Pattern, StringComparison.OrdinalIgnoreCase);
            }
        }

        [Fact]
        public void AdoptedAppxPatternsAreNoLongerInTheSchemaList()
        {
            string schema = RepoFiles.Read(Path.Combine("config", "schema.psd1"));
            foreach (AppxRemovalRule rule in UpstreamSyncPlugin.AppxData())
            {
                Assert.DoesNotContain("@{ Pattern = '" + rule.Pattern + "'", schema);
            }
        }
    }

    public class LatencyTests
    {
        private sealed class Recorder
        {
            public readonly List<string> Writes = new List<string>();
            public readonly HashSet<string> Tweaks = new HashSet<string>();
            public readonly HashSet<string> Components = new HashSet<string>();
            public readonly HashSet<string> Groups = new HashSet<string>();
            public readonly Dictionary<string, bool> TweakDefaults = new Dictionary<string, bool>();

            public DelegateWinEaseHost Host(bool dryRun)
            {
                DelegateWinEaseHost host = new DelegateWinEaseHost("", "", new ImageInfo(26100, 0, "Pro", "amd64"), dryRun);
                host.SetOfflineRegistryAction = delegate(string hive, string path, string name, string type, string data)
                {
                    Writes.Add(hive + "\\" + path + "|" + name + "|" + type + "|" + data);
                };
                // a tweak the test did not mention has the value the plugin passes as its default, like Test-TweakEnabled
                host.IsTweakEnabledFunc = delegate(string key, bool def) { return Tweaks.Contains(key) || (!Off.Contains(key) && def); };
                host.IsComponentEnabledFunc = delegate(string key, bool def) { return Components.Contains(key); };
                host.IsTweakGroupEnabledFunc = delegate(string key, bool def) { return Groups.Contains(key); };
                return host;
            }

            public readonly HashSet<string> Off = new HashSet<string>();

            public IEnumerable<string> Names { get { return Writes.Select(w => w.Split('|')[1]); } }
            public bool Wrote(string name, string data) { return Writes.Any(w => w.Split('|')[1] == name && w.Split('|')[3] == data); }
        }

        private static Recorder Run(Action<Recorder> setup, bool dryRun = false, string phase = "10-registry", PhaseStage stage = PhaseStage.After)
        {
            Recorder rec = new Recorder();
            setup(rec);
            DelegateWinEaseHost host = rec.Host(dryRun);
            new LatencyPlugin().OnPhase(new PhaseContext(phase, stage, host));
            return rec;
        }

        [Fact]
        public void DefaultsWriteHagsPowerThrottlingAndTheGamingNetworkSettings()
        {
            Recorder rec = Run(r => { });
            Assert.True(rec.Wrote("PowerThrottlingOff", "1"));
            Assert.True(rec.Wrote("HwSchMode", "2"));
            Assert.True(rec.Wrote("NetworkThrottlingIndex", "0xffffffff"));
            Assert.True(rec.Wrote("TCPNoDelay", "1"));
            Assert.Equal(4, rec.Writes.Count);
        }

        [Fact]
        public void EveryTweakCanBeSwitchedOff()
        {
            Recorder rec = Run(r => { r.Off.Add("DisablePowerThrottling"); r.Off.Add("EnableHAGS"); r.Off.Add("GamingNetworkTweaks"); });
            Assert.Empty(rec.Writes);
        }

        [Fact]
        public void TheGpuLatencyGroupTurnsHagsOnEvenWithoutTheTweak()
        {
            Recorder rec = Run(r => { r.Off.Add("DisablePowerThrottling"); r.Off.Add("EnableHAGS"); r.Off.Add("GamingNetworkTweaks"); r.Groups.Add("GPULatency"); });
            Assert.Equal(new[] { "HwSchMode" }, rec.Names.ToArray());
        }

        [Fact]
        public void ThreadDpcEnableWritesTheDpcSettingAndTheQuantum()
        {
            Recorder rec = Run(r => { r.Tweaks.Add("ThreadDpcEnable"); });
            Assert.True(rec.Wrote("ThreadDpcEnable", "1"));
            Assert.True(rec.Wrote("Win32PrioritySeparation", "38"));
        }

        [Fact]
        public void AtlasReviOSModeWritesTheQuantumAndTheGamesProfileButNotTheDpcSetting()
        {
            Recorder rec = Run(r => { r.Components.Add("AtlasReviOSMode"); });
            Assert.True(rec.Wrote("Win32PrioritySeparation", "38"));
            Assert.DoesNotContain("ThreadDpcEnable", rec.Names);
            Assert.Contains(rec.Writes, w => w.Contains("Tasks\\Games|Priority|REG_DWORD|6"));
            Assert.DoesNotContain(rec.Writes, w => w.Contains("Tasks\\Pro Audio"));
        }

        [Theory]
        [InlineData("KeepAudioTweaks", true)]
        [InlineData("DAWMode", true)]
        [InlineData("LowLatencyAudioMMCSS", false)]
        public void AnyAudioSwitchWritesTheProAudioProfile(string key, bool component)
        {
            Recorder rec = Run(r => { if (component) r.Components.Add(key); else r.Tweaks.Add(key); });
            Assert.Equal(6, rec.Writes.Count(w => w.Contains("Tasks\\Pro Audio")));
            Assert.Contains(rec.Writes, w => w.EndsWith("Tasks\\Pro Audio|Scheduling Category|REG_SZ|High"));
            Assert.Contains(rec.Writes, w => w.EndsWith("Tasks\\Pro Audio|Clock Rate|REG_DWORD|10000"));
        }

        [Theory]
        [InlineData("MMCSSGaming", true)]
        [InlineData("MMCSSGaming", false)]
        public void TheGamesProfileFollowsTheComponentAndTheTweak(string key, bool component)
        {
            Recorder rec = Run(r => { if (component) r.Components.Add(key); else r.Tweaks.Add(key); });
            Assert.Equal(7, rec.Writes.Count(w => w.Contains("Tasks\\Games")));
        }

        [Fact]
        public void OnlyTheAfterStageOfPhase10Writes()
        {
            Assert.Empty(Run(r => { }, phase: "10-registry", stage: PhaseStage.Before).Writes);
            Assert.Empty(Run(r => { }, phase: "11-unattend", stage: PhaseStage.After).Writes);
        }

        [Fact]
        public void DryRunRecordsAndWritesNothing()
        {
            Recorder rec = new Recorder();
            DelegateWinEaseHost host = rec.Host(true);
            new LatencyPlugin().OnPhase(new PhaseContext("10-registry", PhaseStage.After, host));
            Assert.Empty(rec.Writes);
            Assert.Equal(4, host.Recorded.Count);
        }

        [Fact]
        public void DescribesTheTweaksItImplementsAndAsksForPhase10Only()
        {
            ISet<string> components;
            IDictionary<string, bool> schema = RepoFiles.SchemaSettings(out components);
            PluginDescription d = new LatencyPlugin().Describe();
            Assert.Equal(new[] { "10-registry" }, d.Phases);
            Assert.Empty(d.ReplacesPhases);
            foreach (string key in d.Tweaks) Assert.True(schema.ContainsKey(key), key);
        }

        [Fact]
        public void TheDefaultsPassedToTheHostMatchTheSchema()
        {
            // the plugin asks IsTweakEnabled(key, default); that default has to be the default of config\schema.psd1
            ISet<string> components;
            IDictionary<string, bool> schema = RepoFiles.SchemaSettings(out components);
            string source = File.ReadAllText(Path.Combine(RepoFiles.Root, "src", "WinEase.Plugins.Builtin.Latency", "LatencyPlugin.cs"));
            foreach (Match m in Regex.Matches(source, @"IsTweakEnabled\(""([A-Za-z]+)"", (true|false)\)"))
            {
                string key = m.Groups[1].Value;
                Assert.True(schema.ContainsKey(key), key);
                // LowLatencyAudioMMCSS: the builder always gated this block with a default of false (the schema default is
                // true, which the profile fills in); the plugin keeps the builder's behaviour.
                if (key == "LowLatencyAudioMMCSS") continue;
                Assert.True(schema[key] == (m.Groups[2].Value == "true"), key + ": default differs from config\\schema.psd1");
            }
            foreach (Match m in Regex.Matches(source, @"IsComponentEnabled\(""([A-Za-z]+)"""))
            {
                Assert.Contains(m.Groups[1].Value, components);
            }
        }
    }

    public class PostInstallToolsTests
    {
        private static IDictionary<string, string> RecordedHashes()
        {
            // tests\fixtures\unattend-scripts\hashes.json: the SHA256 of every script, recorded before the scripts became resources
            Dictionary<string, string> result = new Dictionary<string, string>(StringComparer.Ordinal);
            string json = RepoFiles.Read(Path.Combine("tests", "fixtures", "unattend-scripts", "hashes.json"));
            using (System.Text.Json.JsonDocument doc = System.Text.Json.JsonDocument.Parse(json))
            {
                foreach (System.Text.Json.JsonElement item in doc.RootElement.EnumerateArray())
                {
                    string path = item.GetProperty("path").GetString();
                    if (path.StartsWith("scripts/tools/", StringComparison.Ordinal)) result[path.Substring("scripts/tools/".Length)] = item.GetProperty("sha256").GetString();
                }
            }
            return result;
        }

        private static string Hex(byte[] bytes)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return string.Concat(sha.ComputeHash(bytes).Select(b => b.ToString("x2")));
            }
        }

        [Fact]
        public void EmbedsExactlyTheScriptsItHandsOver()
        {
            Assert.Equal(PostInstallToolsPlugin.ToolPaths.OrderBy(p => p, StringComparer.Ordinal), PostInstallToolsPlugin.ResourceToolPaths().OrderBy(p => p, StringComparer.Ordinal));
        }

        [Fact]
        public void EmbeddedScriptsAreByteForByteTheFilesOfScriptsTools()
        {
            IDictionary<string, string> recorded = RecordedHashes();
            Assert.Equal(PostInstallToolsPlugin.ToolPaths.Length, recorded.Count);
            foreach (string path in PostInstallToolsPlugin.ToolPaths)
            {
                byte[] embedded = PostInstallToolsPlugin.ReadResource(path);
                Assert.Equal(recorded[path], Hex(embedded));
                Assert.Equal(File.ReadAllBytes(Path.Combine(RepoFiles.Root, "scripts", "tools", path.Replace('/', Path.DirectorySeparatorChar))), embedded);
            }
        }

        [Fact]
        public void ImageFilesLandInSetupToolsAndFollowNoPostInstallAssets()
        {
            List<ImageFile> files = new PostInstallToolsPlugin().GetImageFiles(new ImageInfo(0, 0, "", "")).ToList();
            Assert.Equal(PostInstallToolsPlugin.ToolPaths.Length, files.Count);
            foreach (ImageFile file in files)
            {
                Assert.Equal(ImageFileRoot.SetupTools, file.Root);
                Assert.Equal("NoPostInstallAssets", file.Setting);
                Assert.False(file.SettingDefault);
                Assert.False(file.WhenEnabled);
                DelegateWinEaseHost.CheckRelativePath(file.RelativePath);
            }
            Assert.Equal("Atlas-ReviOS Tools\\1. Toggle Windows Defender.bat", files[3].RelativePath);
        }

        [Fact]
        public void EncodingIsWhatSetContentWrote()
        {
            byte[] withBom = new byte[] { 0xEF, 0xBB, 0xBF, (byte)'a', (byte)'\n', 0xE3, 0x81, 0x82 };
            byte[] ps1 = PostInstallToolsPlugin.Encode("x.ps1", withBom);
            Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF, (byte)'a', (byte)'\n', 0xE3, 0x81, 0x82, 13, 10 }, ps1);
            // ASCII has no Japanese letter: Set-Content -Encoding ascii wrote '?'
            Assert.Equal(new byte[] { (byte)'a', (byte)'\n', (byte)'?', 13, 10 }, PostInstallToolsPlugin.Encode("x.bat", withBom));
            Assert.Equal(new byte[] { 13, 10 }, PostInstallToolsPlugin.Encode("x.cmd", new byte[0]));
        }

        [Fact]
        public void ScriptsThatRunInTheGuestKeepTheirText()
        {
            foreach (ImageFile file in new PostInstallToolsPlugin().GetImageFiles(new ImageInfo(0, 0, "", "")))
            {
                string text = Encoding.UTF8.GetString(file.Content);
                Assert.EndsWith("\r\n", text);
                Assert.Equal(file.RelativePath.EndsWith(".ps1", StringComparison.Ordinal), file.Content.Length >= 3 && file.Content[0] == 0xEF && file.Content[1] == 0xBB && file.Content[2] == 0xBF);
            }
        }

        [Fact]
        public void HostWritesToTheNamedRootAndRecordsInDryRun()
        {
            string written = null;
            DelegateWinEaseHost host = new DelegateWinEaseHost("C:\\scratch", "", null, false);
            host.WriteImageFileToRootAction = delegate(ImageFileRoot root, string path, byte[] content) { written = root + ":" + path; };
            host.WriteImageFile(ImageFileRoot.SetupTools, "Atlas-ReviOS Tools\\x.bat", new byte[] { 1 });
            Assert.Equal("SetupTools:Atlas-ReviOS Tools\\x.bat", written);

            DelegateWinEaseHost dry = new DelegateWinEaseHost("C:\\scratch", "", null, true);
            dry.WriteImageFileToRootAction = delegate { throw new InvalidOperationException("must not run"); };
            dry.WriteImageFile(ImageFileRoot.SetupTools, "x.bat", new byte[] { 1, 2 });
            Assert.Single(dry.Recorded);
            Assert.Throws<ArgumentException>(delegate { host.WriteImageFile(ImageFileRoot.SetupTools, "..\\x.bat", new byte[0]); });
        }
    }
}
