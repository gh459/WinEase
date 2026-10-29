using System;
using System.Reflection;

namespace WinEase.Plugins
{
    /// <summary>
    /// Plugin DLLs are loaded from bytes (so the file that was hashed is the code that runs). Such an
    /// assembly is not in the default load context, so the runtime asks AssemblyResolve for the contract
    /// assembly it references. This handler answers with the contract assembly the builder loaded. It is
    /// plain C# on purpose: a script block as handler would run PowerShell code inside every assembly
    /// resolution of the process.
    /// </summary>
    public static class PluginAssemblyResolver
    {
        private static readonly object Gate = new object();
        private static Assembly contract;
        private static int contractMajorVersion;
        private static bool installed;

        /// <summary>Remembers the contract assembly and installs the handler once per process.</summary>
        public static void Install(Assembly contractAssembly)
        {
            if (contractAssembly == null) throw new ArgumentNullException("contractAssembly");
            lock (Gate)
            {
                contract = contractAssembly;
                // Cache the contract assembly's major version to avoid heap allocations from Assembly.GetName() during resolution.
                contractMajorVersion = contractAssembly.GetName().Version != null ? contractAssembly.GetName().Version.Major : 0;
                if (installed) return;
                AppDomain.CurrentDomain.AssemblyResolve += OnResolve;
                installed = true;
            }
        }

        private static Assembly OnResolve(object sender, ResolveEventArgs args)
        {
            Assembly current = contract;
            if (current == null) return null;
            AssemblyName requested;
            try { requested = new AssemblyName(args.Name); }
            catch (Exception) { return null; }
            if (!string.Equals(requested.Name, PluginApi.AssemblyName, StringComparison.OrdinalIgnoreCase)) return null;
            // Plugins bind to the major version only. Use cached major version to prevent repeated AssemblyName allocations.
            if (requested.Version != null && requested.Version.Major != contractMajorVersion) return null;
            return current;
        }
    }
}
