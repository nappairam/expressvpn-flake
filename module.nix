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

    tailscaleBypass.enable = lib.mkEnableOption ''
      a systemd unit that pokes a hole in tailscale's `ts-input` chain so
      ExpressVPN's tunnel IPs (100.64.100.1, 100.64.100.5) survive the
      CGNAT anti-spoof DROP. Only relevant when tailscale is also active
      on this host
    '';
  };

  config = lib.mkIf cfg.enable {
    # `tun` for OpenVPN/Lightway tunnel device.
    boot.kernelModules = [ "tun" ];

    # NixOS' default-deny firewall otherwise drops inbound packets on the
    # VPN tunnel even though daemon's killswitch chain already gates outbound.
    networking.firewall.trustedInterfaces = [ "tun0" ];

    # Tailscale's `ts-input` chain drops every packet sourced from
    # 100.64.0.0/10 that arrives on a non-tailscale0 interface (anti-CGNAT-
    # spoof guard). ExpressVPN's tun0 hands out 100.64.100.0/24, so DNS
    # replies (src=100.64.100.1) and tunnel control traffic from the peer
    # (src=100.64.100.5) get dropped → "no DNS", "no internet" while
    # connected. External-IP traffic (src=104.x etc.) is unaffected.
    # Tailscale rebuilds ts-input from scratch on every restart or
    # `tailscale set`, so bind this unit to tailscaled via PartOf so it
    # re-runs on every tailscaled restart.
    systemd.services.expressvpn-tailscale-bypass = lib.mkIf cfg.tailscaleBypass.enable (
      let
        ipts = "${pkgs.iptables}/bin/iptables";
        # VPN-internal IPs that tailscale's CGNAT guard would otherwise
        # drop. .1 is the daemon-pushed DNS server, .5 is the tun0 peer.
        allowSrcs = [
          "100.64.100.1"
          "100.64.100.5"
          "100.64.0.1"
          "100.64.0.5"
        ];
        insertRule = src: ''
          ${ipts} -C ts-input -s ${src} -i tun0 -j RETURN 2>/dev/null \
            || ${ipts} -I ts-input 1 -s ${src} -i tun0 -j RETURN
        '';
        deleteRule = src: ''
          ${ipts} -D ts-input -s ${src} -i tun0 -j RETURN 2>/dev/null || true
        '';
      in
      {
        description = "Re-insert tailscale ts-input bypass for ExpressVPN tunnel IPs";
        wantedBy = [
          "tailscaled.service"
          "expressvpn.service"
        ];
        after = [
          "tailscaled.service"
          "expressvpn.service"
        ];
        partOf = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "expressvpn-tailscale-bypass" ''
            set -eu
            # tailscaled creates ts-input asynchronously after the unit
            # reports ready, so wait for the chain to exist before inserting.
            for _ in $(seq 1 30); do
              ${ipts} -S ts-input >/dev/null 2>&1 && break
              sleep 1
            done
            ${lib.concatMapStringsSep "\n" insertRule allowSrcs}
          '';
          ExecStop = pkgs.writeShellScript "expressvpn-tailscale-bypass-stop" ''
            ${lib.concatMapStringsSep "\n" deleteRule allowSrcs}
          '';
        };
      }
    );

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
      # Daemon invokes helper commands via `/bin/bash -c "..."` (newexec.cpp);
      # NixOS only ships `/bin/sh`, so without this symlink every iptables/ip
      # rule application aborts with "code: 2 No such file or directory".
      "L+ /bin/bash             -    -    -         - ${pkgs.bash}/bin/bash"
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
      # Daemon shells out to a fleet of POSIX utilities via `bash -c "..."`
      # (iptables for the killswitch, ip for policy routing, awk/grep/sed
      # for parsing output, procps for pgrep/killall). Each one missing from
      # the unit's PATH manifests as a cryptic "command not found" warning
      # and a half-applied firewall.
      path = [
        pkgs.iptables
        pkgs.iproute2
        pkgs.gawk
        pkgs.gnugrep
        pkgs.gnused
        pkgs.coreutils
        pkgs.procps
        pkgs.psmisc
        pkgs.util-linux
        pkgs.systemd # for `systemctl` invoked by openvpn-updown.sh
      ];
      serviceConfig = {
        ExecStart = "${installDir}/bin/expressvpn-daemon";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
