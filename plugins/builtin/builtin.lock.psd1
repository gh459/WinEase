# builtin.lock.psd1 - allow list of the plugin DLLs that ship with WinEase (plugins\builtin).
# Only a DLL listed here, with the SHA256 of the file, is loaded. No built-in plugin exists yet.
#
#   File        name of the DLL in plugins\builtin (no path)
#   Sha256      SHA256 of the file (lower-case hex, 64 characters)
#   OnError     Stop (end the build) | Warn (report, go on; default) | Ignore
#   Enabled     $false keeps the entry but skips the plugin
#   Description free text
@{
    Version = 1
    Plugins = @(
    )
}
