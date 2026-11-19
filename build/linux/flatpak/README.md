# Flatpak (Flathub)

Packaging for [Flathub](https://flathub.org) under the app ID
**`com.nextcloud.Office`**. It repackages the signed Nextcloud Office `.deb`
published on
[nextcloud-releases/Office-DesktopEditors](https://github.com/nextcloud-releases/Office-DesktopEditors/releases)
— nothing is compiled inside flatpak-builder.

| File | Purpose |
| --- | --- |
| `com.nextcloud.Office.yml` | Manifest: downloads the x86_64/aarch64 `.deb`, unpacks it into `/app/nextcloud-office` |
| `com.nextcloud.Office.metainfo.xml` | AppStream data shown on flathub.org and in software centers |
| `nextcloud-office.sh` | Launcher, the Flatpak counterpart of `/usr/bin/nextcloud-office-nextcloudoffice` |
| `flathub.json` | Limits Flathub builds to x86_64 and aarch64 |

These files are the source of truth; the Flathub repo
(`flathub/com.nextcloud.Office`) holds a copy plus the screenshots.

## Building locally

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.flatpak.Builder

cd build/linux/flatpak
flatpak run org.flatpak.Builder --user --install-deps-from=flathub \
    --force-clean --install builddir com.nextcloud.Office.yml
flatpak run com.nextcloud.Office
```

Lint the way Flathub's CI does:

```sh
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest com.nextcloud.Office.yml
flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo   # after --repo=repo
```

## Sandbox notes

- File open/save dialogs go through the `FileChooser` portal: the launcher
  passes `--xdg-desktop-portal`, otherwise the app would show a GTK chooser that
  only sees the sandbox.
- Only `xdg-documents` and `xdg-download` are granted directly. Files opened
  from a file manager arrive through the document portal.
- `converter/package.config` says `package = flatpack` (sic), which is the
  string `AppOptions::packageType()` checks for.

## Releasing an update

`x-checker-data` in the manifest lets the
[Flathub external data checker](https://github.com/flathub-infra/flatpak-external-data-checker)
open a PR on the Flathub repo whenever a new release appears on
nextcloud-releases/Office-DesktopEditors. Merging that PR publishes the update.
Add a `<release>` entry to the metainfo for each version.

The checker finds the `.deb` by name, so the asset names
`nextcloud-office-nextcloudoffice_<ver>_x86_64.deb` and
`nextcloud-office-nextcloudoffice_<ver>.aarch64.deb` must stay stable.

## Submitting to Flathub (one time)

See <https://docs.flathub.org/docs/for-app-authors/submission>.

1. Add screenshots of Nextcloud Office (PNG, 16:9, no window shadows) and point
   the `<screenshots>` URLs in the metainfo at their final location.
2. Fork [flathub/flathub](https://github.com/flathub/flathub) **including all
   branches**, then branch from `new-pr`:
   ```sh
   git clone --branch=new-pr git@github.com:<you>/flathub.git
   cd flathub && git switch -c add-com.nextcloud.Office
   cp <DesktopEditors>/build/linux/flatpak/{com.nextcloud.Office.yml,com.nextcloud.Office.metainfo.xml,nextcloud-office.sh,flathub.json} .
   mkdir screenshots && cp <screenshots> screenshots/
   ```
3. Open a PR against **`new-pr`** titled `Add com.nextcloud.Office`. Comment
   `bot, build` to get a test build, and answer reviewer questions.
4. After the merge, Flathub creates `flathub/com.nextcloud.Office` and invites
   you. Accept within a week and enable 2FA.
5. Verify the app on <https://flathub.org/developers>: serve the token it gives
   at `https://nextcloud.com/.well-known/org.flathub.VerifiedApps.txt`.
