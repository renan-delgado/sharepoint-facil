# rclone

`rclone.exe` is not duplicated in this folder. The staging script reads the
release-controlled source at `../../rclone.exe`, verifies its version and SHA-256
from [`../../config/payload.manifest.json`](../../config/payload.manifest.json),
and embeds it in the MSI.

When updating rclone, obtain it from the official release, verify its checksum,
then update all three of the following in the same change:

- `version` and `sha256` in the payload manifest;
- the rclone version in `assets/THIRD-PARTY-NOTICES.txt`;
- this build input at the repository root.

Do not stage `rclone.conf`, `settings.json`, OAuth data, or any user data.
