using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace WinEase.Plugins.Tests
{
    /// <summary>Finds the files of the repository the tests compare the built-in plugins with.</summary>
    internal static class RepoFiles
    {
        public static string Root
        {
            get
            {
                DirectoryInfo dir = new DirectoryInfo(AppContext.BaseDirectory);
                while (dir != null)
                {
                    if (File.Exists(Path.Combine(dir.FullName, "config", "schema.psd1"))) return dir.FullName;
                    dir = dir.Parent;
                }
                throw new InvalidOperationException("config\\schema.psd1 was not found above " + AppContext.BaseDirectory);
            }
        }

        public static string Read(string relativePath)
        {
            return File.ReadAllText(Path.Combine(Root, relativePath));
        }

        /// <summary>The Tweaks and Components entries of config\schema.psd1: key -> Default (true when the entry has none).</summary>
        public static IDictionary<string, bool> SchemaSettings(out ISet<string> components)
        {
            Dictionary<string, bool> result = new Dictionary<string, bool>(StringComparer.Ordinal);
            HashSet<string> componentKeys = new HashSet<string>(StringComparer.Ordinal);
            bool inComponents = false;
            foreach (string line in Read(Path.Combine("config", "schema.psd1")).Split('\n'))
            {
                string trimmed = line.Trim();
                if (trimmed.StartsWith("Components = @(", StringComparison.Ordinal)) inComponents = true;
                else if (trimmed.StartsWith("Tweaks = @(", StringComparison.Ordinal)) inComponents = false;
                Match key = Regex.Match(trimmed, @"^@\{ Key = '([^']+)'");
                if (!key.Success) continue;
                Match def = Regex.Match(trimmed, @"; Default = \$(true|false)");
                result[key.Groups[1].Value] = def.Success && def.Groups[1].Value == "true";
                if (inComponents) componentKeys.Add(key.Groups[1].Value);
            }
            components = componentKeys;
            return result;
        }
    }
}
