using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;

namespace WinEase.Plugins.Builtin.PostInstallTools
{
    /// <summary>
    /// Browser Grabber (Install-Browser), WinEase Control Center and the Atlas-ReviOS maintenance tools. The
    /// scripts are the files of scripts\tools, embedded as resources; the plugin hands them to the builder as
    /// image files for Windows\Setup\Tools, unless -NoPostInstallAssets is set. The bytes are what the
    /// builder used to write with Set-Content: the text re-encoded (UTF-8 with BOM for .ps1, ASCII for the
    /// rest) with a final CRLF.
    /// </summary>
    public sealed class PostInstallToolsPlugin : IWinEasePlugin, IImageFileContributor
    {
        public const string PluginId = "winease.builtin.postinstalltools";
        public const string DataVersion = "1.0.0";
        /// <summary>The component of config\schema.psd1 that switches the staging off.</summary>
        public const string SwitchOff = "NoPostInstallAssets";

        /// <summary>Path in the image below Windows\Setup\Tools, in the order the builder wrote them.</summary>
        public static readonly string[] ToolPaths = new string[]
        {
            "Install-Browser.ps1",
            "Install-Browser.cmd",
            "WinEase Control Center.bat",
            "Atlas-ReviOS Tools/1. Toggle Windows Defender.bat",
            "Atlas-ReviOS Tools/2. Toggle Windows Update.bat",
            "Atlas-ReviOS Tools/3. Toggle Hibernation.bat",
            "Atlas-ReviOS Tools/4. Toggle Bluetooth.bat",
            "Atlas-ReviOS Tools/5. Toggle Print Spooler.bat",
            "Atlas-ReviOS Tools/6. Free Memory & Clear Temp.bat",
            "Atlas-ReviOS Tools/7. Check Activation Status.bat"
        };

        public string Id { get { return PluginId; } }
        public string Version { get { return DataVersion; } }

        public PluginDescription Describe()
        {
            PluginDescription d = new PluginDescription();
            d.Summary = "Post-install tools: Browser Grabber, WinEase Control Center and the Atlas-ReviOS maintenance scripts (Windows\\Setup\\Tools).";
            d.Tweaks = new string[0];
            return d;
        }

        public bool AppliesTo(ImageInfo image)
        {
            return true;
        }

        public void OnPhase(PhaseContext context)
        {
            // data only: the builder writes the files in phase 11-unattend
        }

        public IEnumerable<ImageFile> GetImageFiles(ImageInfo image)
        {
            List<ImageFile> files = new List<ImageFile>();
            foreach (string path in ToolPaths)
            {
                ImageFile file = new ImageFile(path.Replace('/', '\\'), Encode(path, ReadResource(path)));
                file.Root = ImageFileRoot.SetupTools;
                file.Setting = SwitchOff;
                file.SettingDefault = false;
                file.WhenEnabled = false;
                files.Add(file);
            }
            return files;
        }

        /// <summary>The bytes of an embedded script exactly as stored in scripts\tools.</summary>
        public static byte[] ReadResource(string toolPath)
        {
            string wanted = "tools/" + toolPath;
            Assembly assembly = typeof(PostInstallToolsPlugin).Assembly;
            foreach (string name in assembly.GetManifestResourceNames())
            {
                // Avoid string.Replace allocations when resource name has no backslashes or matches directly.
                if (string.Equals(name, wanted, StringComparison.Ordinal) ||
                    (name.IndexOf('\\') >= 0 && string.Equals(name.Replace('\\', '/'), wanted, StringComparison.Ordinal)))
                {
                    using (Stream stream = assembly.GetManifestResourceStream(name))
                    {
                        // Read directly into pre-sized byte array using stream length to eliminate MemoryStream allocations.
                        byte[] buffer = new byte[stream.Length];
                        int offset = 0;
                        while (offset < buffer.Length)
                        {
                            int read = stream.Read(buffer, offset, buffer.Length - offset);
                            if (read == 0) break;
                            offset += read;
                        }
                        return buffer;
                    }
                }
            }
            throw new InvalidOperationException("The tool script is not embedded: " + toolPath);
        }

        /// <summary>The names of all embedded tool scripts (path below scripts\tools, with '/').</summary>
        public static IList<string> ResourceToolPaths()
        {
            List<string> names = new List<string>();
            foreach (string name in typeof(PostInstallToolsPlugin).Assembly.GetManifestResourceNames())
            {
                // Avoid string.Replace allocation when name contains no backslashes.
                string normalised = name.IndexOf('\\') >= 0 ? name.Replace('\\', '/') : name;
                if (normalised.StartsWith("tools/", StringComparison.Ordinal)) names.Add(normalised.Substring("tools/".Length));
            }
            return names;
        }

        /// <summary>
        /// What Set-Content -Encoding utf8 (.ps1) / -Encoding ascii (everything else) wrote for the text of the
        /// file in Windows PowerShell 5.1: the BOM for UTF-8, a final CRLF, '?' for a character ASCII lacks.
        /// </summary>
        public static byte[] Encode(string toolPath, byte[] raw)
        {
            int skip = (raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) ? 3 : 0;
            string text = new UTF8Encoding(false).GetString(raw, skip, raw.Length - skip) + "\r\n";
            if (toolPath.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase))
            {
                byte[] body = new UTF8Encoding(false).GetBytes(text);
                byte[] result = new byte[body.Length + 3];
                result[0] = 0xEF; result[1] = 0xBB; result[2] = 0xBF;
                Buffer.BlockCopy(body, 0, result, 3, body.Length);
                return result;
            }
            return Encoding.ASCII.GetBytes(text);
        }
    }
}
