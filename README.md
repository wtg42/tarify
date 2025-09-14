# tarify

This is a simple tool to create tar archives.

## Dependencies

This project requires `libarchive` to be installed on your system.

### Installation

**macOS (using [Homebrew](https://brew.sh/))**

```bash
brew install libarchive
```

**Linux**

*   **Debian / Ubuntu**
    ```bash
    sudo apt update
    sudo apt install libarchive-dev
    ```

*   **Red Hat / CentOS / Fedora**
    ```bash
    # CentOS/RHEL
    sudo yum install libarchive-devel

    # Fedora
    sudo dnf install libarchive-devel
    ```

*   **Arch Linux**
    ```bash
    sudo pacman -S libarchive
    ```

*   **Alpine Linux**
    ```bash
    sudo apk add libarchive-dev
    ```

## Development

- Zig: develop against nightly/master. Run `zig version` to confirm.
- Tests & scripts: all local/CI test commands are centrally managed under `scripts/` or Makefile targets for consistency.
  - Examples (conventions; scripts will live under `scripts/`):
    - `make test` or `scripts/test_all.sh` → runs `zig build test`
    - `make fmt` or `scripts/fmt.sh` → runs `zig fmt .`
  - Shell scripts should use `#!/usr/bin/env bash` and `set -euo pipefail`.
