# expressvpn-nix

ExpressVPN v14.x (Qt-based App) packaged for NixOS - daemon + CLI (`expressvpnctl`) + GUI client (`expressvpn-client`).

Built from the upstream universal `.run` installer (auto-extracted via `autoPatchelfHook`). Includes a NixOS module that wires `/opt/expressvpn` via `systemd-tmpfiles` and sets up the daemon service.

## Status

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
- `environment.etc."NetworkManager/conf.d/wgexpressvpn.conf"` - keep NM off `wgexpressvpn*`
- `/bin/bash` symlink - daemon shells helpers via hardcoded `/bin/bash -c`

Also disables nixpkgs's stale `services.expressvpn` module (v3 CLI) so the namespace is owned by this flake.

### `allowDNS`

Network Lock permits port 53 only to the resolver the daemon pushes, so a
resolver reachable outside the tunnel stops answering while connected -
Tailscale's MagicDNS at `100.100.100.100`, or a corporate resolver on a subnet
you already bypass. The daemon's own bypass-subnet setting cannot fix it: its
`allowSubnets` anchor is priority 305 and `blockDNS` is 310, so the reject
happens first and port 53 stays broken while every other protocol works.

```nix
services.expressvpn.allowDNS = [ "100.100.100.100" ];
```

Adds `systemd.services.expressvpn-allow-dns`, which marks those queries with
`0x3213` - the mark the daemon already accepts for its own traffic at
`allowVpnFwmark` (priority 390) - so they clear the kill switch before
`blockDNS` sees them. IPv4 and IPv6 entries are both accepted; the family is
detected per entry.

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

## Bumping the version (default public release)

1. Find the new release URL on `expressvpn.works/clients/linux/`
2. Update `version` in `package.nix`
3. Run `nix-prefetch-url <url>` to get the new hash
4. Update `hash` in `package.nix` (use `sha256-...` SRI format)
5. Build - autoPatchelf may need additional `buildInputs` if upstream adds new
   bundled libs (read the build failure)

## Custom installer

The package exposes `version` and `installer` as overridable arguments. To
build a specific installer that isn't on the public CDN, stage the `.run`
locally and pass `requireFile` as `installer`:

```bash
# 1. Drop the installer somewhere and prefetch into the store:
nix store prefetch-file "file:///absolute/path/to/expressvpn-linux-universal-14.2.0.xxxxx.run"
```

```nix
# 2. In your NixOS config, override the package:
services.expressvpn = {
  enable = true;
  package = pkgs.expressvpn.override {
    version = "14.2.0.XXXXX";
    installer = pkgs.requireFile {
      name = "expressvpn-linux-universal-14.2.0.xxxxxx.run";
      hash = "sha256-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
      message = ''
        Stage the ExpressVPN installer before building:
          nix store prefetch-file "file:///path/to/the.run"
      '';
    };
  };
};
```

## License

Module + packaging code: MIT.
Underlying ExpressVPN binary: proprietary (unfree). See ExpressVPN's terms.
