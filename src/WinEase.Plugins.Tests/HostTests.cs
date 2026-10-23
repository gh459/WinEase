using System;
using Xunit;

namespace WinEase.Plugins.Tests
{
    public class HostTests
    {
        private static DelegateWinEaseHost NewHost(bool dryRun, out int[] calls)
        {
            // calls: 0 registry, 1 dism, 2 file
            int[] counters = new int[3];
            calls = counters;
            DelegateWinEaseHost host = new DelegateWinEaseHost(@"C:\scratch", @"C:\WinEase", new ImageInfo(26100, 1, "Pro", "amd64"), dryRun);
            host.SetOfflineRegistryAction = delegate { counters[0]++; };
            host.RunDismFunc = delegate { counters[1]++; return new DismResult(0, "ok"); };
            host.WriteImageFileAction = delegate { counters[2]++; };
            return host;
        }

        [Fact]
        public void WriteOperationsReachTheServicesOutsideDryRun()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            host.SetOfflineRegistry("zSYSTEM", "Software\\X", "V", "REG_DWORD", "1");
            Assert.True(host.RunDism(new[] { "/Get-Packages" }).Succeeded);
            host.WriteImageFile("a\\b.txt", new byte[] { 1 });
            Assert.Equal(new[] { 1, 1, 1 }, calls);
            Assert.Empty(host.Recorded);
        }

        [Fact]
        public void DryRunRecordsAndDoesNothing()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(true, out calls);
            host.SetOfflineRegistry("zSYSTEM", "Software\\X", "V", "REG_DWORD", "1");
            host.RunDism(new[] { "/Get-Packages" });
            host.WriteImageFile("a\\b.txt", new byte[] { 1, 2 });
            Assert.Equal(new[] { 0, 0, 0 }, calls);
            Assert.Equal(3, host.Recorded.Count);
        }

        [Theory]
        [InlineData("..\\evil.txt")]
        [InlineData("a\\..\\..\\evil.txt")]
        [InlineData("C:\\evil.txt")]
        [InlineData("\\evil.txt")]
        [InlineData("")]
        public void ImageFilePathsMustStayRelative(string path)
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            Assert.Throws<ArgumentException>(delegate { host.WriteImageFile(path, new byte[0]); });
            Assert.Equal(0, calls[2]);
        }

        [Fact]
        public void IsTweakEnabledFallsBackToTheDefault()
        {
            DelegateWinEaseHost host = new DelegateWinEaseHost("", "", null, false);
            Assert.True(host.IsTweakEnabled("Anything", true));
            Assert.False(host.IsTweakEnabled("Anything", false));
            host.IsTweakEnabledFunc = delegate(string key, bool def) { return key == "On"; };
            Assert.True(host.IsTweakEnabled("On", false));
            Assert.False(host.IsTweakEnabled("Off", true));
        }

        [Fact]
        public void ReadOnlyPropertiesCarryTheBuildContext()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            Assert.Equal(26100, host.ImageInfo.Build);
            Assert.Equal("amd64", host.ImageInfo.Architecture);
            Assert.Equal(@"C:\scratch", host.ScratchDir);
            Assert.False(host.DryRun);
        }
    }

    public class ResolverTests
    {
        [Fact]
        public void InstallIsIdempotentAndIgnoresOtherAssemblies()
        {
            System.Reflection.Assembly contract = typeof(IWinEasePlugin).Assembly;
            PluginAssemblyResolver.Install(contract);
            PluginAssemblyResolver.Install(contract);
            Assert.Throws<System.IO.FileNotFoundException>(delegate { System.Reflection.Assembly.Load("WinEase.Plugins.DoesNotExist, Version=1.0.0.0"); });
        }

        [Fact]
        public void NullAssemblyIsRejected()
        {
            Assert.Throws<ArgumentNullException>(delegate { PluginAssemblyResolver.Install(null); });
        }
    }

    public class ContractTests
    {
        private sealed class SamplePlugin : IWinEasePlugin, IAppxRemovalContributor
        {
            public string Id { get { return "sample"; } }
            public string Version { get { return "1.0.0"; } }
            public PluginDescription Describe() { return new PluginDescription { MinBuild = 26100 }; }
            public bool AppliesTo(ImageInfo image) { return image.Build >= Describe().MinBuild; }
            public void OnPhase(PhaseContext context) { context.Host.Log(LogLevel.Info, context.Phase + ":" + context.Stage); }
            public System.Collections.Generic.IEnumerable<string> GetAppxRemovals(ImageInfo image) { return new[] { "Contoso.*" }; }
        }

        [Fact]
        public void AppliesToFollowsTheBuildRange()
        {
            SamplePlugin plugin = new SamplePlugin();
            Assert.True(plugin.AppliesTo(new ImageInfo(26100, 0, "Pro", "amd64")));
            Assert.False(plugin.AppliesTo(new ImageInfo(22631, 0, "Pro", "amd64")));
        }

        [Fact]
        public void OnPhaseGetsStageAndHost()
        {
            string logged = null;
            DelegateWinEaseHost host = new DelegateWinEaseHost("", "", null, false);
            host.LogAction = delegate(LogLevel level, string message) { logged = message; };
            new SamplePlugin().OnPhase(new PhaseContext("05-appx", PhaseStage.Before, host));
            Assert.Equal("05-appx:Before", logged);
        }

        [Fact]
        public void DescriptionDefaultsAreEmptyNotNull()
        {
            PluginDescription d = new PluginDescription();
            Assert.Empty(d.Tweaks);
            Assert.Empty(d.Phases);
            Assert.Empty(d.ReplacesPhases);
        }
    }
}
