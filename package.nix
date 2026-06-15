# ExpressVPN (v14.x, Qt-based App) packaged from upstream universal .run installer.
# Pairs with `./module.nix` which symlinks /opt/expressvpn -> this output
# so hardcoded paths inside the bundled binaries resolve.
{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  bash,
  gnutar,
  gzip,
  # Helpers that openvpn-updown.sh shells out to. The Lightway daemon spawns the
  # up/down script with a hard-coded PATH=/usr/bin:/usr/sbin:/bin:/sbin, so it
  # cannot resolve any of these via the systemd unit's PATH - we have to bake the
  # nix-store paths into the script itself.
  coreutils,
  gnugrep,
  gnused,
  gawk,
  systemd,
  iproute2,
  iptables,
  procps,
  psmisc,
  util-linux,
  # --- Overridable installer source ---
  # Defaults to the public v14.1 release downloaded over HTTPS. Override
  # `version` to pin a different upstream tag (used in default URL + pname);
  version ? "14.2.0.13635",
  installer ? fetchurl {
    url = "https://www.expressvpn.works/clients/linux/expressvpn-linux-universal-${version}_release.run";
    hash = "sha256-4V6tDr9LIlC8b3KxIjT9WWcOzeNhim5eDKOv72umCKQ=";
  },
  # autoPatchelf inputs (NEEDED libs the bundle doesn't ship)
  stdenv,
  glib,
  zlib,
  brotli,
  dbus,
  fontconfig,
  freetype,
  libxkbcommon,
  libdrm,
  libGL,
  libglvnd,
  wayland,
  nss,
  nspr,
  libnl,
  libcap_ng,
  mesa,
  libxrender,
  libxext,
  libxi,
  libxrandr,
  libxfixes,
  libxdamage,
  libxcursor,
  libxcomposite,
  libxshmfence,
  libxcb-util,
  libxcb-image,
  libxcb-keysyms,
  libxcb-render-util,
  libxcb-wm,
  libxcb-cursor,
  libxkbfile,
  libice,
  libsm,
  libx11,
  libxcb,
}:


let
  archDir =
    if stdenvNoCC.hostPlatform.isx86_64 then
      "x64"
    else if stdenvNoCC.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "expressvpn: unsupported platform ${stdenvNoCC.hostPlatform.system}";
in
stdenvNoCC.mkDerivation {
  pname = "expressvpn";
  inherit version;
  src = installer;

  nativeBuildInputs = [
    autoPatchelfHook
    bash
    gnutar
    gzip
  ];

  buildInputs = [
    stdenv.cc.cc.lib # libstdc++, libgcc_s
    glib
    zlib
    brotli
    dbus
    fontconfig
    freetype
    libxkbcommon
    libdrm
    libGL
    libglvnd
    wayland
    nss
    nspr
    libnl
    libcap_ng
    mesa
    libx11
    libxcb
    libxcb-util
    libxcb-image
    libxcb-keysyms
    libxcb-render-util
    libxcb-wm
    libxcb-cursor
    libxkbfile
    libice
    libsm
    libxrender
    libxext
    libxi
    libxrandr
    libxfixes
    libxdamage
    libxcursor
    libxcomposite
    libxshmfence
  ];

  # The .run is a Makeself self-extracting archive (gzip+tar). Extract via --noexec.
  unpackPhase = ''
    runHook preUnpack
    cp "$src" ./installer.run
    chmod +x ./installer.run
    bash ./installer.run --noexec --target ./payload --keep >/dev/null
    rm ./installer.run
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/expressvpn $out/bin $out/share/applications $out/share/pixmaps
    cp -r payload/${archDir}/expressvpnfiles/* $out/expressvpn/

    # Upstream openvpn-updown.sh hardcodes /usr/bin/{systemctl,resolvectl}. Drop
    # the absolute paths so they resolve via the PATH we bake in next.
    substituteInPlace $out/expressvpn/bin/openvpn-updown.sh \
      --replace '/usr/bin/systemctl' 'systemctl' \
      --replace '/usr/bin/resolvectl' 'resolvectl'

    # Lightway's helium daemon spawns this script with PATH=/usr/bin:/usr/sbin:
    # /bin:/sbin, so grep/sed/awk/tr/realpath/systemctl/resolvectl/ip can't be
    # found and the up-script exits 127 - which tears the tunnel down a few
    # seconds after connect. Inject a fixed PATH at the top of the script so it
    # resolves all helpers from /nix/store regardless of the parent's PATH.
    sed -i "2i export PATH=${
      lib.makeBinPath [
        coreutils
        gnugrep
        gnused
        gawk
        systemd
        iproute2
        iptables
        procps
        psmisc
        util-linux
      ]
    }:\$PATH" $out/expressvpn/bin/openvpn-updown.sh

    # expressvpn-support-tool ELF has `/usr/bin/zip\0` baked in for bundling
    # debug reports. Patch the C string in place to `zip\0` + null padding so
    # the runtime resolves `zip` via PATH (the module puts `pkgs.zip` on PATH).
    # 13-byte pattern, 13-byte replacement - no offset shift.
    sed -i 's|/usr/bin/zip\x00|zip\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00|g' \
      $out/expressvpn/bin/expressvpn-support-tool

    ln -s $out/expressvpn/bin/expressvpnctl $out/bin/expressvpnctl

    # Wrap expressvpn-client. The app's own argv parser swallows everything ahead of
    # QApplication, so QT_QPA_PLATFORM env doesn't change Qt's plugin choice - but
    # QApplication still honours the `-platform <name>` Qt argv flag. Inject it
    # based on $XDG_SESSION_TYPE so the GUI works on Wayland-only sessions
    # (niri, etc.) where the upstream .desktop's forced XDG_SESSION_TYPE=X11
    # leaves xcb with no display.
    cat > $out/bin/expressvpn-client <<'EOF'
    #!${bash}/bin/bash
    # The bundle ships Qt6's platform plugin for Wayland but not the
    # `wayland-graphics-integration-client` plugin dir, so Qt fails to load the
    # `wayland-egl` client buffer integration and aborts when QtQuick tries to
    # create a GLES2 context. Force Qt Quick's software scenegraph as a
    # workaround until upstream ships those plugins.
    : "''${QT_QUICK_BACKEND:=software}"
    export QT_QUICK_BACKEND
    PLAT_ARGS=()
    if ! printf '%s\n' "$@" | grep -qx '\-platform'; then
      case "$XDG_SESSION_TYPE" in
        wayland) PLAT_ARGS=(-platform wayland) ;;
        x11|tty|"") PLAT_ARGS=(-platform xcb) ;;
      esac
    fi
    exec @out@/expressvpn/bin/expressvpn-client "''${PLAT_ARGS[@]}" "$@"
    EOF
    substituteInPlace $out/bin/expressvpn-client --replace '@out@' "$out"
    chmod +x $out/bin/expressvpn-client

    cp payload/${archDir}/installfiles/app-icon.png $out/share/pixmaps/expressvpn.png
    # Route .desktop Exec through our wrapper rather than the X11-forcing upstream line.
    cp payload/${archDir}/installfiles/expressvpn.desktop $out/share/applications/expressvpn.desktop
    substituteInPlace $out/share/applications/expressvpn.desktop \
      --replace 'Exec=env XDG_SESSION_TYPE=X11 /opt/expressvpn/bin/expressvpn-client' \
                "Exec=$out/bin/expressvpn-client" \
      --replace 'Path=/opt/expressvpn/bin/' \
                "Path=$out/expressvpn/bin/"

    runHook postInstall
  '';

  # Bundled libs live at $out/expressvpn/lib; autoPatchelf preserves the existing
  # $ORIGIN/../lib RUNPATH so the binaries find them at runtime.
  appendRunpaths = [ "$ORIGIN/../lib" ];

  # The bundle ships QML/Qt plugin .so files for features the app doesn't actually
  # use (VirtualKeyboard, StateMachine, EglFS, Particles, ...). Their backing Qt6
  # modules aren't bundled; treat the missing deps as non-fatal - Qt simply won't
  # load those plugins.
  autoPatchelfIgnoreMissingDeps = [
    "libQt6LabsSharedImage.so.6"
    "libQt6LabsSettings.so.6"
    "libQt6LabsQmlModels.so.6"
    "libQt6StateMachine.so.6"
    "libQt6StateMachineQml.so.6"
    "libQt6QmlXmlListModel.so.6"
    "libQt6QuickParticles.so.6"
    "libQt6QuickTimeline.so.6"
    "libQt6VirtualKeyboard.so.6"
    "libQt6QmlLocalStorage.so.6"
    "libQt6Sql.so.6"
    "libQt6EglFSDeviceIntegration.so.6"
    "libQt6EglFsKmsSupport.so.6"
    "libQt6WlShellIntegration.so.6"
    "libQt6Bodymovin.so.6"
    "libQt6LabsAnimation.so.6"
    "libQt6LabsFolderListModel.so.6"
    "libQt6LabsWavefrontMesh.so.6"
    "libQt6QuickTest.so.6"
    "libQt6Test.so.6"
  ];

  # Don't strip - bundle ships debug symbols and ICU data tables.
  dontStrip = true;

  meta = {
    description = "ExpressVPN Qt client (CLI + GUI + daemon)";
    homepage = "https://www.expressvpn.com";
    license = lib.licenses.unfree;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "expressvpnctl";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
