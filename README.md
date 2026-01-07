rm-safe
======

Safe `rm` that moves files to Trash instead of permanently deleting them. Includes a small `rm` shim and guidance for macOS, common Linux sudoers setups, and NixOS.

Features
- Moves files/directories to OS trash (XDG trash on Linux, Finder Trash on macOS).
- Refuses to touch protected locations (`/`, `/etc`, `/nix/store`, etc.).
- Works with sudo via a wrapper, not shell aliases.
- Restores manual trash entries with `--undo` or `--undo-picker` (gum or fzf).
- Built-in test suite: `bin/rm-safe --test`.

Files
- `bin/rm-safe` — main tool.
- `bin/rm` — wrapper shim that routes `rm` -> `rm-safe`, warns/falls back to system `rm` safely (recursion guard).
- `bin/test/rm-safe_test` — undo/restore tests.
- `bin/test/rm_override_test` — shim tests.

Quick start (user-level)
1. Put `bin` on your `PATH` (e.g., `export PATH="$PWD/bin:$PATH"`).
2. Optional: remove any `alias rm=…` so the shim is used directly.
3. Run `bin/rm-safe --help` and `bin/test/rm_override_test`.

Platform notes
macOS (defaults keep user PATH under sudo)
- Symlink or copy `bin/rm` into `~/bin` (or any user directory already ahead of `/bin`).
- `sudo rm …` will hit the shim because PATH is preserved by default.

Linux with sudo `secure_path`
- Create a root-owned override dir, e.g. `/usr/bin/overrides` (0755, root:root).
- Install the shim there as `rm` and ensure `rm-safe` is reachable (same dir is simplest).
- In sudoers (via `visudo`), prepend the override dir:
  ```
  Defaults secure_path="/usr/bin/overrides:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  ```
- Avoid adding broad dirs like `/usr/local/bin` just to get the shim; overrides keeps blast-radius small.

NixOS (declarative)
- Build/install `rm-safe` and the shim into a root-owned path on PATH, e.g. `/run/wrappers/bin`.
- Example snippet:
  ```
  # configuration.nix
  {
    security.sudo.extraConfig = ''
      Defaults secure_path=/run/wrappers/bin:/usr/bin:/bin
    '';
    environment.systemPackages = [ rm-safe-package ];
    environment.pathsToLink = [ "/run/wrappers/bin" ];
  }
  ```
- Ensure `rm` wrapper in that path execs `rm-safe`; shim already uses `command -p rm` to reach the real rm when needed.

Cautions
- Log-rotate/cleanup scripts that expect permanent deletion will move files to trash when the shim is first in PATH; they should call `/bin/rm` explicitly if deletion is intended.
- The shim warns to stderr if `rm-safe` is missing and falls back to system `rm`.

Testing
- Shim: `bin/test/rm_override_test`
- Main tool: `bin/rm-safe --test`
- Undo/restore: `bin/test/rm-safe_test`

License
- MIT (see LICENSE)
