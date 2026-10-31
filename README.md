# Racky

Racky is a Mac app that runs your coding agents (Claude Code, Codex, OpenCode) in organized sessions and gives their subagents
their own isolated computers (a small Linux virtual machine with a browser), with nothing else to install.

## Install (for users)

**Requirements**

- A Mac with Apple silicon (M1 or later) running **macOS 26 or later**. Racky then runs computers itself, **no Docker needed**.
  On an older macOS or an Intel Mac, Racky still works if you install Docker (Docker Desktop or OrbStack) and it uses that instead.
- At least one agent CLI installed and signed in: [Claude Code](https://claude.com/claude-code), Codex or OpenCode. Racky never
  signs in for you; onboarding tells you what is missing.
- About 2 GB of free disk space for the computer runtime (see below).
- For Python notebooks in Data: [uv](https://docs.astral.sh/uv/) (`brew install uv`). The first notebook downloads JupyterLab and
  pandas through it (about a minute, once).

**Steps**

1. Download `Racky.dmg` from the [latest release](https://github.com/me/racky/releases/latest), open it and drag
   **Racky** onto **Applications**.
2. Open Racky. The first time, macOS says it can't verify the developer: click **Done**, open
   **System Settings > Privacy & Security**, scroll down and click **Open Anyway**, then confirm. Only needed once.

   Rather use Terminal? This installs and opens Racky with no prompt (run it again to update):

   ```sh
   curl -fsSL https://github.com/me/racky/releases/latest/download/install.sh | bash
   ```
3. Follow the onboarding checklist: agent CLIs found and signed in, **Login Items** approval for the Racky background agent
   (System Settings > General > Login Items & Extensions, switch Racky on; it keeps your terminals alive when you close the window),
   and the computer runtime.

**What gets downloaded on first use.** The app itself is small. The first time an agent asks for a computer, Racky downloads the
computer runtime once (about **475 MB**: a Linux kernel, the guest init and the computer image), checks every file against a
SHA-256 baked into the app, prepares it (about a minute) and never needs the network for it again. Progress shows on the computer
row and in Settings > Computers > Computer runtime. After that a computer starts in about two seconds. The runtime takes about
1.4 GB on disk, under `~/Library/Application Support/Racky/vz`.

**Good to know**

- Computers are virtual machines hosted by the app: they stop when you quit Racky (Keep Running in the background keeps them).
- Nothing leaves your Mac because of Racky itself; the only download is the runtime above, from this repository's releases.
- Uninstall: quit Racky, drag it to the Trash, and delete `~/Library/Application Support/Racky` if you also want the data and
  the runtime gone. Remove the Login Item in System Settings if it is still listed.

## Releasing (for maintainers)

Nothing below publishes by itself: each script prints the `gh` command for you to run.

```sh
# 1. Runtime files (once per runtime change). Needs Docker only here, to build the computer image.
scripts/vz/fetch-kernel.sh                    # Kata kernel, ~650 MB download -> build/vz-assets
scripts/vz/build-image.sh                     # computer image + vminit -> build/vz-assets
scripts/vz/stage-release.sh                   # copies to build/release/runtime-<v>/, sha256, rewrites runtime/vz-manifest.json
# commit runtime/vz-manifest.json, then publish with the command stage-release.sh prints:
gh release create runtime-<v> ...

# 2. The app. Builds Release (arm64), signs, verifies, creates build/release/Racky.dmg + Racky.dmg.sha256.
scripts/release.sh <version>                  # ad-hoc by default
RACKY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" RACKY_NOTARY_PROFILE=<notarytool profile> scripts/release.sh <version>
gh release create v<version> build/release/Racky.dmg build/release/Racky.dmg.sha256 ...   # printed by release.sh
```

Without `RACKY_NOTARY_PROFILE` the notarization step is skipped (users then need **Open Anyway**, as above).

## Development

Requires Xcode with Swift 6 on Apple silicon. Pinned tool versions are in `scripts/tool-versions.txt` (checked by `scripts/bootstrap.sh`).

```sh
scripts/test.sh all                                           # the package tests: unit in parallel, then the integration suites serially
scripts/build.sh                                              # the app bundle (Xcode project generated from project.yml)
```

The product spec lives in `docs/rebuild/spec/` (`03-screens.md` §24 is the source of the automation IDs: `scripts/gen-automation-ids.py`).
Open work is tracked in `docs/BACKLOG.md`.

## Security model (summary)

- An agent running on the Mac (light mode) has **the same powers as the user**: shell, files and the Docker socket. Racky does not isolate it and does not claim to.
- A computer isolates the **browser**, the network and the work tools; in isolated mode it also isolates the agent, with the limits shown in the UI.
- Local sockets are `0600` with `getpeereid`; the daemon only accepts the signed app. The `ctl` automation channel is off by default.
- Secrets live in the app's vault (one Keychain item); no token in `argv`, `docker inspect`, logs or the diagnostics bundle.
- Racky never asks for Screen Recording and only asks for notifications when you press `Allow Notifications`.

Third-party marks belong to their owners.
