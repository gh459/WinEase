# plugins\user

Your own plugin DLLs go here. The DLLs are not committed (`.gitignore`).

A DLL in this folder is **only loaded when it is listed with its SHA256 in
`config\user\plugins.lock.psd1`**. The WinUI window does this for you (`plugins.addUser`): it shows the
hash of the file you picked and registers it after you confirm. A DLL that is not listed, or whose hash
changed, is reported in the build log and not loaded.

See [plugins\README.md](../README.md) for the plugin contract and how to write a plugin.
