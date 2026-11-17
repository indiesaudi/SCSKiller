# SCSKiller-Armada

SCSKiller-Armada is an unofficial fork of [SCSKiller](https://github.com/BlueHeisenberg/SCSKiller), the Shader Compilation Stutter
Killer. It is based on SCSKiller and is not affiliated with or endorsed by the upstream project.

The fork focuses on support that upstream doesn't have yet:

- **arm64 Linux**: a native aarch64 build for arm64 PCs and handhelds.
- **Xodus Nexus**: Microsoft Store PC games installed with Xodus Nexus (Nexus Launcher).
- **RE Engine games**: Resident Evil Requiem and Onimusha: Way of the Sword, recorded with the recorder loaded from
  outside the game folder.

For what SCSKiller is, how it works and how to use it, see the
[upstream README](https://github.com/BlueHeisenberg/SCSKiller#readme). What this fork changes is listed in
[CHANGELOG.md](CHANGELOG.md).

## Builds

Builds of this fork come from this repository's [Releases](https://github.com/indiesaudi/SCSKiller-Armada/releases) page. It
installs beside upstream's app, with its own data folder and updates. The Windows zip is unsigned and doesn't update
itself.

These builds, their bugs and their behaviour are this fork's responsibility, not upstream's.

## Issues

Please open an [issue here](https://github.com/indiesaudi/SCSKiller-Armada/issues) only for what this fork adds: arm64 Linux,
Xodus Nexus, and the RE Engine games (Resident Evil Requiem and Onimusha: Way of the Sword). Everything else belongs
with the [upstream project](https://github.com/BlueHeisenberg/SCSKiller/issues).

## Licence

GPL-3.0-or-later ([LICENSE](LICENSE)), with an additional permission for Oodle, the Windows App SDK and graphics driver
libraries ([LICENSE-EXCEPTION.txt](LICENSE-EXCEPTION.txt)). Third-party components:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

SCSKiller is Copyright (C) 2026 The SCSKiller authors. This fork keeps those copyright notices.

Not affiliated with any GPU maker, engine maker or game publisher. All product names are trademarks of their owners.
