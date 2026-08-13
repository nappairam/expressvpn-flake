# ExpressVPN v14.x daemon + GUI NixOS module. Pairs with ./package.nix.
#
# The bundled binaries hardcode /opt/expressvpn paths (qt.conf, daemon helper lookups,
# `LD_LIBRARY_PATH=/opt/expressvpn/lib` in the upstream service). This module wires up
# /opt/expressvpn via systemd-tmpfiles: bin/lib/plugins/qml/share are symlinks into the
# nix store; etc/ and var/ are writable state owned by the expressvpn group.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.expressvpn;
  installDir = "/opt/expressvpn";
  # Daemon shells out to a fleet of POSIX utilities via `bash -c "..."`
  # (iptables for the killswitch, ip for policy routing, awk/grep/sed for
  # parsing output, procps for pgrep/killall, findutils/e2fsprogs for
  # openvpn-updown.sh's xargs/lsattr). Merged into ONE buildEnv on purpose:
  # the daemon relays its $PATH to openvpn-updown.sh as `--path` args
  # chunked at 120 chars (OpenVPN's OPTION_PARM_SIZE workaround), and
  # OpenVPN additionally truncates script argv at MAX_PARMS=16. A
  # multi-directory PATH overflows that limit - the script loses `--dns`
  # and gets a PATH cut mid-store-hash, the up script fails, and openvpn
  # aborts every connection attempt ~2s in. One merged dir keeps the PATH
  # at 2 entries -> 2 chunks -> the whole command fits.
  daemonTools = pkgs.buildEnv {
    name = "expressvpn-daemon-tools";
    paths = [
      pkgs.iptables
      pkgs.iproute2
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.coreutils
      pkgs.findutils # xargs in openvpn-updown.sh
      pkgs.e2fsprogs # lsattr in openvpn-updown.sh
      pkgs.procps
      pkgs.psmisc
      pkgs.util-linux
      pkgs.systemd # for `systemctl` invoked by openvpn-updown.sh
    ];
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
    # kill/uptime/etc. exist in several of these; first match wins.
    ignoreCollisions = true;
  };
  # The daemon's exec.cpp spawns `/bin/bash -c "..."` with a stripped
  # environment (unlike newexec.cpp, which passes PATH). Upstream Ubuntu
  # survives because bash's compiled-in fallback PATH finds /usr/bin;
  # nixpkgs bash falls back to PATH=/no-such-path, so every such helper
  # exits 127. WireGuard configures its tunnel IP through exec.cpp
  # (`ip addr add ... dev wgexpressvpn0`), so without this shim the
  # interface never comes up. Only defaults PATH when unset - callers
  # that provide one keep theirs.
  # Append rather than replace-when-unset: exec.cpp hardcodes
  # PATH=/usr/bin:/bin:/usr/local/bin (verified via strace), so the PATH is
  # never actually empty - it just points at directories NixOS doesn't
  # have. Appending keeps any caller-provided entries at higher priority.
  bashWithDefaultPath = pkgs.writeScript "bash-with-default-path" ''
    #!${pkgs.bash}/bin/bash
    export PATH="''${PATH:+$PATH:}${daemonTools}/bin:${daemonTools}/sbin"
    exec ${pkgs.bash}/bin/bash "$@"
  '';

  # The daemon accepts its own traffic at the allowVpnFwmark anchor
  # (priority 390) on this mark, well ahead of blockDNS at 310. Borrowing it
  # is what lets an allowlisted resolver through; nothing else in the
  # daemon's OUTPUT chain runs early enough.
  allowDnsMark = "0x3213";
  # Mark rather than accept, because the verdict has to come from a chain
  # the daemon owns - anything we append to the filter chain ourselves is
  # either rebuilt on the next applyRules() or ordered behind the reject.
  dnsMarkRule =
    addr: proto:
    let
      ipt = if lib.hasInfix ":" addr then "ip6tables" else "iptables";
    in
    {
      cmd = "${pkgs.iptables}/bin/${ipt} -w -t mangle";
      spec = "OUTPUT -d ${addr} -p ${proto} --dport 53 -j MARK --set-mark ${allowDnsMark}";
    };
  dnsMarkRules = lib.concatMap (addr: map (dnsMarkRule addr) [
    "udp"
    "tcp"
  ]) cfg.allowDNS;
in
{
  # nixpkgs ships an older v3 CLI-only `services.expressvpn` module. This
  # flake supersedes it with the v14.x Qt App build, so disable the
  # upstream module to free the namespace.
  disabledModules = [ "services/networking/expressvpn.nix" ];

  options.services.expressvpn = {
    enable = lib.mkEnableOption "ExpressVPN daemon + Qt GUI client";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "ExpressVPN package to use.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        User names to add to the `expressvpn` group. The Qt client connects
        to the daemon socket under `/opt/expressvpn/var/` (group-readable),
        so any user that should drive the VPN from the GUI/CLI needs
        membership.
      '';
    };

    allowDNS = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "100.100.100.100" ];
      description = ''
        Resolvers whose queries should survive Network Lock's DNS blocker.

        Network Lock permits port 53 only to the resolver the daemon pushes,
        so a resolver reachable outside the tunnel - Tailscale's MagicDNS, a
        corporate resolver on a bypassed subnet - stops answering while
        connected. Listing it here marks its queries with the mark the
        daemon already accepts for its own traffic, which is evaluated
        before the DNS reject.

        Note the daemon's own bypass-subnet setting cannot do this: it is
        consulted *after* the reject, so it restores every protocol except
        port 53. Addresses may be IPv4 or IPv6; the family is detected per
        entry.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `tun` for OpenVPN/Lightway tunnel device.
    boot.kernelModules = [ "tun" ];

    # NixOS' default-deny firewall otherwise drops inbound packets on the
    # VPN tunnel even though daemon's killswitch chain already gates outbound.
    networking.firewall.trustedInterfaces = [ "tun0" ];

    # WireGuard routes via a wg-quick-style catch-all rule
    # (`not fwmark 0x3213 lookup evpnWgrt` -> default dev wgexpressvpn0)
    # instead of a host route to the endpoint, so with the strict
    # `fib saddr . mark . iif` check the encrypted replies arriving on the
    # physical interface resolve to the wrong iif and get dropped - the
    # handshake works (finishes before the rule is installed), then the
    # tunnel goes one-way. OpenVPN/Lightway are unaffected (they add a /32
    # to the server via the physical gateway). Loose mode only requires
    # *some* route back to the source, the standard setting for
    # policy-routed VPNs.
    networking.firewall.checkReversePath = lib.mkDefault "loose";

    # Appending to mangle OUTPUT is deliberate. iptables creates the builtin
    # chain on demand if nothing has yet, the daemon's own chain there only
    # sets marks and returns, and its mustBeFirst repositioning removes just
    # its own duplicate jumps - so a rule appended after it survives both the
    # daemon's rule rebuilds and its restarts.
    systemd.services.expressvpn-allow-dns = lib.mkIf (cfg.allowDNS != [ ]) {
      description = "Mark DNS to allowlisted resolvers so Network Lock permits it";
      wantedBy = [ "multi-user.target" ];
      after = [ "expressvpn.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "expressvpn-allow-dns-add" (
          lib.concatMapStringsSep "\n" (rule: ''
            ${rule.cmd} -C ${rule.spec} 2> /dev/null || ${rule.cmd} -A ${rule.spec}
          '') dnsMarkRules
        );
        ExecStop = pkgs.writeShellScript "expressvpn-allow-dns-del" (
          lib.concatMapStringsSep "\n" (rule: ''
            ${rule.cmd} -D ${rule.spec} 2> /dev/null || true
          '') dnsMarkRules
        );
      };
    };

    users.groups.expressvpn = { };
    users.groups.expressvpnhnsd = { };
    users.users = lib.genAttrs cfg.users (_: { extraGroups = [ "expressvpn" ]; });

    environment.systemPackages = [
      cfg.package
      # `expressvpn-support-tool` execs `zip` (via PATH after our binary
      # patch) to bundle diagnostic reports.
      pkgs.zip
    ];

    # Daemon writes to etc/ (settings.json) and var/ (logs, state).
    # Static bundle dirs are symlinks into the nix store.
    systemd.tmpfiles.rules = [
      "d  ${installDir}         0755 root root      - -"
      "L+ ${installDir}/bin     -    -    -         - ${cfg.package}/expressvpn/bin"
      "L+ ${installDir}/lib     -    -    -         - ${cfg.package}/expressvpn/lib"
      "L+ ${installDir}/plugins -    -    -         - ${cfg.package}/expressvpn/plugins"
      "L+ ${installDir}/qml     -    -    -         - ${cfg.package}/expressvpn/qml"
      "L+ ${installDir}/share   -    -    -         - ${cfg.package}/expressvpn/share"
      # Upstream installer leaves these world-traversable (chmod 755 on every
      # dir under /opt/expressvpn). Match it so the daemon socket at
      # /opt/expressvpn/var/daemon.sock stays reachable by any user that
      # needs to talk to the daemon (the socket itself is srwxrwxrwx).
      "d  ${installDir}/etc     0755 root expressvpn - -"
      "d  ${installDir}/var     0755 root expressvpn - -"
      # Split tunneling: daemon expects /opt/expressvpn/etc/cgroup/net_cls to
      # be a cgroup-v1 net_cls mount-point. systemd.mounts (below) does the
      # actual mount; tmpfiles just ensures the parent dir exists.
      "d  ${installDir}/etc/cgroup           0755 root root - -"
      "d  ${installDir}/etc/cgroup/net_cls   0755 root root - -"
      # Daemon invokes helper commands via `/bin/bash -c "..."`; NixOS only
      # ships `/bin/sh`, so without this every iptables/ip rule application
      # aborts with "code: 2 No such file or directory". Points at a shim
      # (not bare bash) - see bashWithDefaultPath above.
      "L+ /bin/bash             -    -    -         - ${bashWithDefaultPath}"
    ];

    # Split tunneling needs the legacy cgroup-v1 `net_cls` controller. NixOS
    # boots cgroup-v2 unified, so net_cls isn't mounted anywhere - daemon's
    # GUI then reports split tunneling as unsupported. Mount it as a named v1
    # hierarchy at the path the daemon hardcodes. The kernel still ships the
    # controller (CONFIG_CGROUP_NET_CLASSID=y) even under unified v2.
    systemd.mounts = [
      {
        # `mount -t cgroup -o net_cls none /opt/expressvpn/etc/cgroup/net_cls`
        what = "none";
        where = "${installDir}/etc/cgroup/net_cls";
        type = "cgroup";
        options = "net_cls";
        before = [ "expressvpn.service" ];
        requiredBy = [ "expressvpn.service" ];
      }
    ];

    # Match upstream wgexpressvpn.conf - keep NetworkManager off the wireguard ifaces
    # so the daemon's DNS settings on those ifaces aren't clobbered when the user
    # switches networks.
    environment.etc."NetworkManager/conf.d/wgexpressvpn.conf".text = ''
      [keyfile]
      unmanaged-devices=interface-name:wgexpressvpn*
    '';

    systemd.services.expressvpn = {
      description = "ExpressVPN daemon";
      wantedBy = [ "multi-user.target" ];
      # ExecStart references /opt/expressvpn (tmpfiles symlink), not the
      # nix-store path, so the unit text doesn't change across package
      # bumps. Tie restart explicitly to the package derivation so
      # switch-to-configuration picks up version upgrades.
      restartTriggers = [ cfg.package ];
      after = [
        "network.target"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      # Daemon binaries dlopen from /opt/expressvpn/lib via $ORIGIN/../lib RUNPATH already,
      # but upstream's unit sets LD_LIBRARY_PATH explicitly - mirror that for parity.
      environment.LD_LIBRARY_PATH = "${installDir}/lib";
      # NOT `path = [ daemonTools ]`: NixOS appends five default packages to
      # every service path (coreutils/findutils/grep/sed/systemd), which
      # pushes the PATH back over OpenVPN's MAX_PARMS budget - see the
      # daemonTools comment. Setting environment.PATH directly keeps it at
      # exactly two entries.
      environment.PATH = lib.mkForce "${daemonTools}/bin:${daemonTools}/sbin";
      serviceConfig = {
        ExecStart = "${installDir}/bin/expressvpn-daemon";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
