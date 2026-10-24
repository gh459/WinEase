using System;
using System.Collections.Generic;

namespace WinEase.Plugins
{
    /// <summary>The services the builder gives a plugin. With DryRun the write operations are recorded and do nothing.</summary>
    public interface IWinEaseHost
    {
        void Log(LogLevel level, string message);
        bool IsTweakEnabled(string key, bool defaultValue);
        /// <summary>Value of a component setting of config\schema.psd1 (for example AtlasReviOSMode), after presets and switches.</summary>
        bool IsComponentEnabled(string key, bool defaultValue);
        /// <summary>Value of a tweak group of config\schema.psd1 (for example GPULatency).</summary>
        bool IsTweakGroupEnabled(string group, bool defaultValue);
        /// <summary>Writes a value into a loaded offline hive (zSYSTEM, zSOFTWARE, zDEFAULT, zNTUSER, zCOMPONENTS).</summary>
        void SetOfflineRegistry(string hive, string path, string name, string type, string data);
        /// <summary>Runs DISM against the mounted image. The builder adds /Image itself and refuses verbs that change the mount.</summary>
        DismResult RunDism(string[] arguments);
        /// <summary>Writes a file below Windows\Setup\Scripts\Plugins\&lt;plugin id&gt; in the image.</summary>
        void WriteImageFile(string relativePath, byte[] content);
        /// <summary>Writes a file below one of the fixed image folders (see ImageFileRoot).</summary>
        void WriteImageFile(ImageFileRoot root, string relativePath, byte[] content);

        string ScratchDir { get; }
        string WinEaseDir { get; }
        ImageInfo ImageInfo { get; }
        bool DryRun { get; }
    }

    /// <summary>
    /// IWinEaseHost made of delegates. The PowerShell side of the builder fills the delegates; the
    /// DryRun rule and the argument checks live here, so they hold for every implementation.
    /// </summary>
    public sealed class DelegateWinEaseHost : IWinEaseHost
    {
        private readonly List<string> recorded = new List<string>();

        public DelegateWinEaseHost(string scratchDir, string winEaseDir, ImageInfo imageInfo, bool dryRun)
        {
            ScratchDir = scratchDir ?? string.Empty;
            WinEaseDir = winEaseDir ?? string.Empty;
            ImageInfo = imageInfo ?? new ImageInfo(0, 0, string.Empty, string.Empty);
            DryRun = dryRun;
        }

        public Action<LogLevel, string> LogAction { get; set; }
        public Func<string, bool, bool> IsTweakEnabledFunc { get; set; }
        public Func<string, bool, bool> IsComponentEnabledFunc { get; set; }
        public Func<string, bool, bool> IsTweakGroupEnabledFunc { get; set; }
        public Action<string, string, string, string, string> SetOfflineRegistryAction { get; set; }
        public Func<string[], DismResult> RunDismFunc { get; set; }
        public Action<string, byte[]> WriteImageFileAction { get; set; }
        public Action<ImageFileRoot, string, byte[]> WriteImageFileToRootAction { get; set; }

        public string ScratchDir { get; private set; }
        public string WinEaseDir { get; private set; }
        public ImageInfo ImageInfo { get; private set; }
        public bool DryRun { get; private set; }

        /// <summary>The write operations a DryRun run would have made.</summary>
        public IList<string> Recorded { get { return recorded.AsReadOnly(); } }

        public void Log(LogLevel level, string message)
        {
            if (LogAction != null) LogAction(level, message);
        }

        public bool IsTweakEnabled(string key, bool defaultValue)
        {
            if (IsTweakEnabledFunc == null) return defaultValue;
            return IsTweakEnabledFunc(key, defaultValue);
        }

        public bool IsComponentEnabled(string key, bool defaultValue)
        {
            if (IsComponentEnabledFunc == null) return defaultValue;
            return IsComponentEnabledFunc(key, defaultValue);
        }

        public bool IsTweakGroupEnabled(string group, bool defaultValue)
        {
            if (IsTweakGroupEnabledFunc == null) return defaultValue;
            return IsTweakGroupEnabledFunc(group, defaultValue);
        }

        public void SetOfflineRegistry(string hive, string path, string name, string type, string data)
        {
            if (string.IsNullOrEmpty(hive)) throw new ArgumentException("hive is required", "hive");
            if (string.IsNullOrEmpty(path)) throw new ArgumentException("path is required", "path");
            if (DryRun)
            {
                Record("registry " + hive + "\\" + path + " [" + name + "] " + type + " = " + data);
                return;
            }
            if (SetOfflineRegistryAction == null) throw new NotSupportedException("The builder gave no registry service.");
            SetOfflineRegistryAction(hive, path, name, type, data);
        }

        public DismResult RunDism(string[] arguments)
        {
            if (arguments == null || arguments.Length == 0) throw new ArgumentException("arguments are required", "arguments");
            if (DryRun)
            {
                Record("dism " + string.Join(" ", arguments));
                return new DismResult(0, string.Empty);
            }
            if (RunDismFunc == null) throw new NotSupportedException("The builder gave no DISM service.");
            return RunDismFunc(arguments);
        }

        public void WriteImageFile(string relativePath, byte[] content)
        {
            CheckRelativePath(relativePath);
            if (content == null) throw new ArgumentNullException("content");
            if (DryRun)
            {
                Record("file " + relativePath + " (" + content.Length + " bytes)");
                return;
            }
            if (WriteImageFileAction == null) throw new NotSupportedException("The builder gave no file service.");
            WriteImageFileAction(relativePath, content);
        }

        public void WriteImageFile(ImageFileRoot root, string relativePath, byte[] content)
        {
            if (root == ImageFileRoot.PluginFolder)
            {
                WriteImageFile(relativePath, content);
                return;
            }
            CheckRelativePath(relativePath);
            if (content == null) throw new ArgumentNullException("content");
            if (DryRun)
            {
                Record("file [" + root + "] " + relativePath + " (" + content.Length + " bytes)");
                return;
            }
            if (WriteImageFileToRootAction == null) throw new NotSupportedException("The builder gave no file service.");
            WriteImageFileToRootAction(root, relativePath, content);
        }

        /// <summary>Throws unless the path is relative and stays below its folder.</summary>
        public static void CheckRelativePath(string relativePath)
        {
            if (string.IsNullOrWhiteSpace(relativePath)) throw new ArgumentException("A relative path is required.", "relativePath");
            if (relativePath.IndexOf(':') >= 0 || relativePath.StartsWith("\\") || relativePath.StartsWith("/"))
                throw new ArgumentException("The path has to be relative: " + relativePath, "relativePath");
            foreach (string part in relativePath.Split('\\', '/'))
            {
                if (part == "..") throw new ArgumentException("The path leaves its folder: " + relativePath, "relativePath");
            }
        }

        private void Record(string text)
        {
            recorded.Add(text);
            Log(LogLevel.Info, "[DryRun] would do: " + text);
        }
    }
}
