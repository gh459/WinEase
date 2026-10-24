# Security notes for WinEase

WinEase builds a Windows installation image. What ends up inside that image (and in
the folders the build leaves behind) can include secrets. This page is the checklist
to go through **before you share, upload or hand over an ISO, a profile, a log or a
work folder**. The security *options* (what each tweak weakens and how to undo it)
are in [`docs/SECURITY_OPTIONS.md`](docs/SECURITY_OPTIONS.md).

To report a vulnerability in WinEase itself, open a private security advisory on the
GitHub repository (or contact the maintainer) instead of a public issue.

## The account password

* There is **no fixed default password**. `-UserPassword` defaults to an empty string,
  so the local account is created with an empty password unless you pass one
  (`-UserPassword`, or the password field of the GUI). Builds before this change used
  a fixed default password (see "Migration" below).
* A password you set is written, in clear text, into the answer file of the image
  (`autounattend.xml`, `<PlainText>true</PlainText>`, in the ISO and in the image). That is how unattended Windows
  Setup takes it. Anyone who gets the ISO can read it.
* The network use of a blank password is blocked in every build
  (`LimitBlankPasswordUse = 1`); an empty password only works at the console.
* The password is **not saved in profiles**: `-SaveProfile` and the GUI never write
  `UserPassword`. If you load an older profile that still contains it, it is used for
  that build and the builder prints a warning; delete the key from the file.
* Set a real password after the first sign-in (`net user <name> <password>`).

## What the first logon cleans up (and what it does not)

When `ConfigureWinlogon` (auto-logon) is on, the image arms `AutoAdminLogon` and the
Winlogon `DefaultPassword`. The first logon then:

* sets `AutoAdminLogon` and `ForceAutoLogon` to 0 and removes `DefaultPassword`, reads
  the values back, and logs `OK` / `FAILED` (never the value) to
  `C:\ProgramData\WinEase\Logs\firstlogon-child.log` (`[AutoLogon-Cleanup]` lines);
* deletes the copies of the answer file that Setup keeps:
  `C:\Windows\Panther\unattend.xml` (also `Panther\unattend` and `Panther\UnattendGC`)
  and `C:\Windows\System32\Sysprep\unattend.xml` (both folders are also cleared of the
  `autounattend.xml` name the build writes), plus the OOBE helper
  `C:\Windows\Setup\Scripts\WinEase-oobe-autologon-repair.ps1` (it holds the password
  as Base64). A file that cannot be deleted is reported as a warning in the same log.

This only protects the **installed system**. It does not change the ISO you built:
the ISO itself still contains `autounattend.xml` with the password.

Not verified: this was checked by automated tests of the script text, not on a real
installation. How Windows Setup behaves with an empty password plus AutoLogon, and
whether the Panther files can be deleted at that point, is untested. After a test
install, read the `[AutoLogon-Cleanup]` lines and look for the files yourself.

## Checklist before you share an ISO

Tick every line, or do not share.

- [ ] **Password**: the ISO was built with an empty password, or you accept that the
      password you used is readable by everyone who gets the ISO (use a throw-away one).
- [ ] **Auto-logon**: `ConfigureWinlogon` is off unless you need it. If it is on, the
      image logs in without a password prompt until the first sign-in.
- [ ] **Answer files**: the build writes the answer file to three places: the ISO root
      (`autounattend.xml`), and inside the image to `Windows\Panther\unattend.xml` and
      `Windows\System32\Sysprep\autounattend.xml`. Open them and check the `<Password>`
      values and account names. Removing the ISO-root copy does not remove the copies
      inside `install.wim`.
- [ ] **Panther copies**: on a machine you installed from the ISO, confirm that
      `C:\Windows\Panther\unattend.xml` and `Sysprep\unattend.xml` are gone before you
      capture that machine as an image or template.
- [ ] **Logs**: `logs\` (builder transcript, `*.config.json` snapshots) and
      `C:\ProgramData\WinEase\Logs` on installed systems. Passwords, tokens and product
      keys are redacted by pattern in the custom-script logs, but read a log before you
      attach it to an issue.
- [ ] **Reports**: `WinEase_report.html` and any exported diagnostics can name your
      machine, paths and the options you chose.
- [ ] **Work directory**: the work folder (default `Documents\WinEase_workspace`) holds
      the mounted/extracted image, including the answer file with the password. Delete
      it, and do not zip it up.
- [ ] **Profiles**: JSON profiles no longer store the password; an old profile may
      still contain `UserPassword`. Remove the key. Check `SourceDrive`, `WorkDir` and
      `UserName` too.
- [ ] **Product keys**: WinEase does not ship a product key. If you added one (answer
      file, a custom script under `config\user`, a post-install tool), remove it from
      the image and from any script you share.
- [ ] **Custom scripts and plugins**: they run with full administrator rights at first
      logon. Share only what you wrote or reviewed, without embedded credentials.

## Migration note

Earlier builds used the fixed default password `WinEase123!` (builder default, answer
file and the Winlogon value). **Every ISO built before this change contains that
password** in `autounattend.xml`, and a machine installed from such an ISO may still
have it as the account password. Change it with `net user <name> <new password>`, treat
those ISOs as non-shareable, and rebuild them.
