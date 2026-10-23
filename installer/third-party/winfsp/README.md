# WinFsp build input

The recommended `Setup.exe` chains the reviewed publisher MSI in this folder
before the application MSI.

Pinned release:

- WinFsp 2.2.26215, 2026 Beta4 (`v2.2B4`), a prerelease;
- upstream asset:
  `https://github.com/winfsp/winfsp/releases/download/v2.2B4/winfsp-2.2.26215.msi`;
- local file: `winfsp.msi`;
- SHA-256:
  `2ECB5C89405488A95BBD8A01875E02C48534FD37BBDFD84488F7590464D65944`.

This prerelease was selected because it includes security vulnerability fixes
and deadlock fixes relevant to write and rename operations. The build stops if
the local MSI does not match `../../config/winfsp.manifest.json`.

The bundle always runs this publisher MSI so it can maintain or upgrade an
existing WinFsp 2.x installation. Presence of the launcher service alone does
not suppress the package. Legacy WinFsp 1.x may need to be removed followed by
a reboot before installing this 2.x package.

Review the upstream release before changing this dependency. Update the source
URL, version, SHA-256, binary, and documentation together. The bundle keeps
WinFsp on application uninstall because it is a shared filesystem prerequisite;
administrators can manage it independently.
