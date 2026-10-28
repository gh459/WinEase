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
        public void RunDismRejectsNullOrEmptyArguments()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);

            ArgumentException exNull = Assert.Throws<ArgumentException>(() => host.RunDism(null));
            Assert.Equal("arguments", exNull.ParamName);

            ArgumentException exEmpty = Assert.Throws<ArgumentException>(() => host.RunDism(new string[0]));
            Assert.Equal("arguments", exEmpty.ParamName);

            Assert.Equal(0, calls[1]);
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

        [Fact]
        public void WriteImageFileRejectsNullContent()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            ArgumentNullException ex1 = Assert.Throws<ArgumentNullException>(() => host.WriteImageFile("file.txt", null));
            Assert.Equal("content", ex1.ParamName);

            ArgumentNullException ex2 = Assert.Throws<ArgumentNullException>(() => host.WriteImageFile(ImageFileRoot.SetupTools, "file.txt", null));
            Assert.Equal("content", ex2.ParamName);

            Assert.Equal(0, calls[2]);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        public void SetOfflineRegistryRejectsNullOrEmptyHive(string hive)
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            ArgumentException ex = Assert.Throws<ArgumentException>(() => host.SetOfflineRegistry(hive, "Software\\X", "V", "REG_DWORD", "1"));
            Assert.Equal("hive", ex.ParamName);
            Assert.Equal(0, calls[0]);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        public void SetOfflineRegistryRejectsNullOrEmptyPath(string path)
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            ArgumentException ex = Assert.Throws<ArgumentException>(() => host.SetOfflineRegistry("zSYSTEM", path, "V", "REG_DWORD", "1"));
            Assert.Equal("path", ex.ParamName);
            Assert.Equal(0, calls[0]);
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

        [Theory]
        [InlineData("file.txt")]
        [InlineData("subfolder/file.txt")]
        [InlineData("subfolder\\file.txt")]
        [InlineData("a/b/c.txt")]
        [InlineData("a\\b\\c.txt")]
        [InlineData(".hiddenfile")]
        [InlineData("folder..name/file.txt")]
        public void CheckRelativePathAcceptsValidRelativePaths(string path)
        {
            DelegateWinEaseHost.CheckRelativePath(path);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData("\t")]
        [InlineData("C:\\path\\file.txt")]
        [InlineData("d:file.txt")]
        [InlineData("\\leadingbackslash\\file.txt")]
        [InlineData("/leadingslash/file.txt")]
        [InlineData("..")]
        [InlineData("..\\evil.txt")]
        [InlineData("../evil.txt")]
        [InlineData("a/b/../evil.txt")]
        [InlineData("a\\b\\..\\evil.txt")]
        public void CheckRelativePathRejectsInvalidRelativePaths(string path)
        {
            ArgumentException ex = Assert.Throws<ArgumentException>(() => DelegateWinEaseHost.CheckRelativePath(path));
            Assert.Equal("relativePath", ex.ParamName);
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
        public void ComponentsAndGroupsFallBackToTheDefaultAndFollowTheBuilder()
        {
            DelegateWinEaseHost host = new DelegateWinEaseHost("", "", null, false);
            Assert.True(host.IsComponentEnabled("AtlasReviOSMode", true));
            Assert.False(host.IsTweakGroupEnabled("GPULatency", false));
            host.IsComponentEnabledFunc = delegate(string key, bool def) { return key == "On"; };
            host.IsTweakGroupEnabledFunc = delegate(string key, bool def) { return key == "Group"; };
            Assert.True(host.IsComponentEnabled("On", false));
            Assert.False(host.IsComponentEnabled("Off", true));
            Assert.True(host.IsTweakGroupEnabled("Group", false));
            Assert.False(host.IsTweakGroupEnabled("Other", true));
        }

        [Fact]
        public void PluginFolderRootIsTheDefaultWriteOfTheFileService()
        {
            int[] calls;
            DelegateWinEaseHost host = NewHost(false, out calls);
            host.WriteImageFile(ImageFileRoot.PluginFolder, "a.txt", new byte[] { 1 });
            Assert.Equal(1, calls[2]);
            ImageFile file = new ImageFile("x", new byte[0]);
            Assert.Equal(ImageFileRoot.PluginFolder, file.Root);
            Assert.True(file.WhenEnabled);
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

        [Theory]
        [InlineData("invalid, version=invalid")]
        [InlineData("")]
        [InlineData("a=b=c")]
        public void OnResolveCatchesExceptionWhenAssemblyNameIsInvalid(string invalidName)
        {
            System.Reflection.Assembly contract = typeof(IWinEasePlugin).Assembly;
            PluginAssemblyResolver.Install(contract);

            System.Reflection.MethodInfo onResolveMethod = typeof(PluginAssemblyResolver).GetMethod(
                "OnResolve",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);

            Assert.NotNull(onResolveMethod);

            ResolveEventArgs args = new ResolveEventArgs(invalidName);
            object result = onResolveMethod.Invoke(null, new object[] { null, args });

            Assert.Null(result);
        }

        [Fact]
        public void OnResolveReturnsContractAssemblyWhenNameAndVersionMatch()
        {
            System.Reflection.Assembly contract = typeof(IWinEasePlugin).Assembly;
            PluginAssemblyResolver.Install(contract);

            System.Reflection.MethodInfo onResolveMethod = typeof(PluginAssemblyResolver).GetMethod(
                "OnResolve",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);

            Assert.NotNull(onResolveMethod);

            ResolveEventArgs args = new ResolveEventArgs("WinEase.Plugins.Abstractions, Version=1.0.0.0");
            object result = onResolveMethod.Invoke(null, new object[] { null, args });

            Assert.Same(contract, result);
        }

        [Fact]
        public void OnResolveReturnsNullWhenMajorVersionMismatches()
        {
            System.Reflection.Assembly contract = typeof(IWinEasePlugin).Assembly;
            PluginAssemblyResolver.Install(contract);

            System.Reflection.MethodInfo onResolveMethod = typeof(PluginAssemblyResolver).GetMethod(
                "OnResolve",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);

            Assert.NotNull(onResolveMethod);

            ResolveEventArgs args = new ResolveEventArgs("WinEase.Plugins.Abstractions, Version=99.0.0.0");
            object result = onResolveMethod.Invoke(null, new object[] { null, args });

            Assert.Null(result);
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

    public class DismResultTests
    {
        [Theory]
        [InlineData(0, true)]
        [InlineData(3010, true)]
        [InlineData(1, false)]
        [InlineData(87, false)]
        [InlineData(-1, false)]
        [InlineData(3011, false)]
        public void SucceededEvaluatesExitCodeCorrectly(int exitCode, bool expectedSucceeded)
        {
            DismResult result = new DismResult(exitCode, "Output");
            Assert.Equal(exitCode, result.ExitCode);
            Assert.Equal("Output", result.Output);
            Assert.Equal(expectedSucceeded, result.Succeeded);
        }

        [Fact]
        public void NullOutputDefaultsToEmptyString()
        {
            DismResult result = new DismResult(0, null);
            Assert.Equal(string.Empty, result.Output);
        }
    }
}
