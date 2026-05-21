# expressvpn-nix

ExpressVPN v14.x (Qt-based App) packaged for NixOS - daemon + CLI (`expressvpnctl`) + GUI client (`expressvpn-client`).

Built from the upstream universal `.run` installer (auto-extracted via `autoPatchelfHook`). Includes a NixOS module that wires `/opt/expressvpn` via `systemd-tmpfiles`, sets up the daemon service, and provides an optional bypass for tailscale's CGNAT anti-spoof drop.

## Status

- Default build: **v14.1.1.13156** (public release, fetched from `expressvpn.works`)
- Tested on NixOS unstable, x86_64-linux
- `aarch64-linux` declared in `meta.platforms` but untested
- Unfree (proprietary upstream)

## Quick start

```nix
{
  inputs.expressvpn.url = "github:nappairam/expressvpn-flake";
  inputs.expressvpn.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, expressvpn, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        expressvpn.nixosModules.default
        {
          nixpkgs.config.allowUnfree = true;

          services.expressvpn = {
            enable = true;
            users = [ "alice" ];
            # Only if you also run tailscale and hit the CGNAT drop
            tailscaleBypass.enable = true;
          };
        }
      ];
    };
  };
}
```

Then `sudo nixos-rebuild switch --flake .#myhost`. The default v14.1 installer is downloaded automatically.

After switch:

- Daemon: `systemctl status expressvpn.service`
- CLI:    `expressvpnctl status`
- GUI:    `expressvpn-client` (or via your launcher)

## What the module sets up

- `boot.kernelModules = [ "tun" ]` - tunnel device
- `networking.firewall.trustedInterfaces = [ "tun0" ]` - inbound on tunnel
- Two groups: `expressvpn`, `expressvpnhnsd`
- `systemd-tmpfiles` rules creating `/opt/expressvpn/{bin,lib,plugins,qml,share}` as symlinks into the nix store + writable `etc/`, `var/` owned by group `expressvpn`
- `systemd.services.expressvpn` - daemon (`expressvpn-daemon`) with `LD_LIBRARY_PATH` + helper PATH (iptables, ip, awk, etc.) baked in
- Optional `systemd.services.expressvpn-tailscale-bypass` - see above
- `environment.etc."NetworkManager/conf.d/wgexpressvpn.conf"` - keep NM off `wgexpressvpn*`
- `/bin/bash` symlink - daemon shells helpers via hardcoded `/bin/bash -c`

Also disables nixpkgs's stale `services.expressvpn` module (v3 CLI) so the namespace is owned by this flake.

## Why so many workarounds?

The upstream `.run` is a Makeself archive that drops binaries with hardcoded
absolute paths (`/usr/bin/systemctl`, `/opt/expressvpn/...`,
`LD_LIBRARY_PATH=/opt/expressvpn/lib`) and a daemon that shells out to a fleet
of POSIX utilities via a hardcoded `PATH=/usr/bin:/usr/sbin:/bin:/sbin`.

NixOS has none of those paths. Without the patches in `package.nix` +
`module.nix`:

- Killswitch only half-applies (no `iptables` on PATH)
- GUI on Wayland aborts trying to load missing Qt EGL integration plugin

See inline comments in `package.nix` / `module.nix` for each fix's rationale.

## Bumping the version

1. Find the new release URL on `expressvpn.works/clients/linux/`
2. Update `version` in `package.nix`
3. Run `nix-prefetch-url <url>` to get the new hash
4. Update `hash` in `package.nix` (use `sha256-...` SRI format)
5. Build - autoPatchelf may need additional `buildInputs` if upstream adds new
   bundled libs (read the build failure)

## License

Module + packaging code: MIT.
Underlying ExpressVPN binary: proprietary (unfree). See ExpressVPN's terms.
