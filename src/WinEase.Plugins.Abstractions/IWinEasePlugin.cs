using System.Collections.Generic;

namespace WinEase.Plugins
{
    /// <summary>
    /// A WinEase plugin. The builder creates one instance per plugin class (public, with a public
    /// parameterless constructor) and calls it around every phase.
    /// </summary>
    public interface IWinEasePlugin
    {
        string Id { get; }
        string Version { get; }
        PluginDescription Describe();
        /// <summary>Decides from the image (build, UBR, edition, architecture) whether the plugin takes part.</summary>
        bool AppliesTo(ImageInfo image);
        void OnPhase(PhaseContext context);
    }

    // The contributor interfaces are optional. They are the main way to follow a new Windows build:
    // the plugin only returns data and the builder applies it.

    /// <summary>Registry values, merged into the config\registry table run of phase 10.</summary>
    public interface IRegistryContributor
    {
        IEnumerable<RegistryEntry> GetRegistryEntries(ImageInfo image);
    }

    /// <summary>Provisioned AppX package names (wildcards allowed) removed in phase 05-appx.</summary>
    public interface IAppxRemovalContributor
    {
        IEnumerable<string> GetAppxRemovals(ImageInfo image);
    }

    /// <summary>Like IAppxRemovalContributor, but every pattern names the setting that controls it, so the package
    /// is only removed when the user asked for it (the same rules as AppxRemoval in config\schema.psd1).</summary>
    public interface IAppxRemovalRuleContributor
    {
        IEnumerable<AppxRemovalRule> GetAppxRemovalRules(ImageInfo image);
    }

    /// <summary>Packages, capabilities and features removed in phase 06-fod.</summary>
    public interface IFodRemovalContributor
    {
        IEnumerable<FodRemoval> GetFodRemovals(ImageInfo image);
    }

    /// <summary>Start types of services, written in the services section of phase 10-registry.</summary>
    public interface IServiceStartContributor
    {
        IEnumerable<ServiceStart> GetServiceStarts(ImageInfo image);
    }

    /// <summary>Files placed into the image in phase 11-unattend. A DLL never runs inside the guest:
    /// a script that has to run there is handed over as a file.</summary>
    public interface IImageFileContributor
    {
        IEnumerable<ImageFile> GetImageFiles(ImageInfo image);
    }
}
