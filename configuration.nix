{ config, pkgs, lib, ... }:

let
  # Native Noctalia v5 from the stable channel, with its built-in Polkit agent.
  koboldNoctalia = pkgs.writeShellApplication {
    name = "kobold-noctalia";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export NOCTALIA_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia-nixos"
      mkdir -p "$NOCTALIA_CONFIG_HOME/noctalia"
      ln -sfnT /etc/xdg/noctalia/nixos.toml "$NOCTALIA_CONFIG_HOME/noctalia/00-nixos.toml"
      exec ${pkgs.noctalia}/bin/noctalia "$@"
    '';
  };
  # Niri's idle policy; gtklock is independent of any compositor shell.
  koboldLock = pkgs.writeShellApplication {
    name = "kobold-lock";
    text = ''
      exec ${pkgs.gtklock}/bin/gtklock -d
    '';
  };
  koboldIdle = pkgs.writeShellApplication {
    name = "kobold-idle";
    text = ''
      exec ${pkgs.swayidle}/bin/swayidle -w \
        timeout 600 '${koboldLock}/bin/kobold-lock' \
        timeout 660 '${config.programs.niri.package}/bin/niri msg action power-off-monitors' \
        resume '${config.programs.niri.package}/bin/niri msg action power-on-monitors' \
        lock '${koboldLock}/bin/kobold-lock' \
        before-sleep '${koboldLock}/bin/kobold-lock'
    '';
  };
in
{
  imports = [
    ./hardware-configuration.nix
  ];

  # ============================================================
  # KOBOLD NIXOS — ThinkPad T495 / Ryzen 5 PRO 3500U
  # NixOS 26.05, single normal user, Wayland-only workstation.
  # No flakes, no Home Manager, no third-party Nix modules/caches.
  # ============================================================

  # ------------------------------------------------------------
  # BOOT / KERNEL
  # ------------------------------------------------------------
  boot = {
    loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
        editor = false;
      };
      efi.canTouchEfiVariables = true;
      timeout = 2;
    };

    # Early KMS for the integrated AMD GPU and KVM acceleration.
    initrd.kernelModules = [ "amdgpu" ];
    kernelModules = [ "kvm-amd" ];

    # T495-specific backlight behavior used by the upstream T495 hardware profile.
    kernelParams = [
      "quiet"
      "acpi_backlight=native"
    ];

    # Keep /tmp predictable and avoid stale state across boots.
    tmp.cleanOnBoot = true;

    # Small, intentional hardening/performance delta.
    kernel.sysctl = {
      # ZRAM-oriented memory policy.
      "vm.swappiness" = 150;
      "vm.page-cluster" = 0;

      # Kernel information disclosure / same-user process hardening.
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.yama.ptrace_scope" = 1;
      "kernel.unprivileged_bpf_disabled" = 2;
      "fs.suid_dumpable" = 0;

      # Unsafe shared-directory patterns.
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;

      # Workstation network hardening. IPv6 stays enabled.
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.secure_redirects" = 0;
      "net.ipv4.conf.default.secure_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.default.accept_source_route" = 0;
    };
  };

  # Prevent replacing the running kernel through kexec and disable hibernation.
  # Suspend remains available.
  security.protectKernelImage = true;

  # Required for Nix sandboxing, Flatpak and rootless containers.
  security.allowUserNamespaces = true;

  # Keep SMT: this CPU is 4C/8T and disabling it has a meaningful performance cost.
  security.allowSimultaneousMultithreading = true;
  security.forcePageTableIsolation = false;

  # ------------------------------------------------------------
  # HARDWARE / STORAGE / POWER
  # ------------------------------------------------------------
  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;

    graphics.enable = true;

    # Native ThinkPad TrackPoint support, without third-party hardware modules.
    trackpoint.enable = true;

    bluetooth = {
      enable = true;
      # Preserve the Kobold policy: radio available, but not forced on at boot.
      powerOnBoot = false;
    };
  };

  # Safe on Btrfs and ext4. Put Btrfs-specific options such as compress=zstd:1
  # in hardware-configuration.nix after the installer has created the filesystem.
  fileSystems."/".options = [ "noatime" ];

  services.fstrim = {
    enable = true;
    interval = "weekly";
  };

  # TLP is more useful than power-profiles-daemon on the Zen+ 3500U because it
  # lets us express the measured T495 policy directly.
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "schedutil";
      CPU_SCALING_GOVERNOR_ON_BAT = "schedutil";

      CPU_BOOST_ON_AC = 1;
      CPU_BOOST_ON_BAT = 0;

      RUNTIME_PM_ON_AC = "auto";
      RUNTIME_PM_ON_BAT = "auto";

      # Kept from the previous T495 configuration because autosuspend caused
      # real peripheral lag/disconnects. Revisit later with per-device denylisting.
      USB_AUTOSUSPEND = 0;
    };
  };

  # ------------------------------------------------------------
  # MEMORY / OOM
  # ------------------------------------------------------------
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };

  # No disk swap baseline: favor responsiveness and let oomd intervene instead
  # of allowing long NVMe-thrashing stalls. Add encrypted disk swap later only
  # if a measured workload requires it.
  swapDevices = lib.mkForce [ ];

  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableSystemSlice = false;
    enableUserSlices = true;
  };

  services.earlyoom.enable = false;

  # ------------------------------------------------------------
  # NETWORK
  # ------------------------------------------------------------
  networking = {
    hostName = "kobold";

    networkmanager.enable = true;
    modemmanager.enable = false;

    nftables.enable = true;

    firewall = {
      enable = true;
      rejectPackets = false; # DROP rather than REJECT.
      allowPing = true;
      checkReversePath = "loose"; # VPN/container/libvirt friendly.
      logRefusedConnections = false;
      logReversePathDrops = false;
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };

  # Avoid recreating the old custom DNS stack; NetworkManager owns normal DNS.
  services.resolved.enable = false;

  # ------------------------------------------------------------
  # LOCALE / KEYBOARD
  # ------------------------------------------------------------
  time.timeZone = "America/Sao_Paulo";

  i18n = {
    defaultLocale = "pt_BR.UTF-8";
    extraLocaleSettings = {
      LC_TIME = "pt_BR.UTF-8";
      LC_MONETARY = "pt_BR.UTF-8";
    };
  };

  console.keyMap = "br-abnt2";

  # XWayland and applications that consult system XKB data.
  services.xserver = {
    enable = false;
    xkb.layout = "br";
  };

  environment.sessionVariables = {
    XKB_DEFAULT_LAYOUT = "br";
    TERMINAL = "alacritty";
    CONTAINER_MANAGER = "podman";
    EDITOR = "hx";
    VISUAL = "hx";
    LIBVIRT_DEFAULT_URI = "qemu:///system";
  };

  # ------------------------------------------------------------
  # WAYLAND DESKTOP — Niri
  # ------------------------------------------------------------
  programs.niri = {
    enable = true;
    useNautilus = false;
  };

  services.displayManager = {
    defaultSession = "niri";
    ly = {
      enable = true;
      x11Support = false;
    };
  };

  # Keep GNOME's screencast backend for Niri, with GTK file dialogs.
  xdg.portal = {
    enable = true;
    config.niri."org.freedesktop.impl.portal.FileChooser" = "gtk";
    config.niri."org.freedesktop.impl.portal.Secret" = lib.mkForce "none";
  };
  # System fallback; ~/.config/niri/config.kdl takes precedence.
  environment.etc."niri/config.kdl".text = ''
    input {
      keyboard { xkb { layout "br"; }; }
      touchpad { tap; natural-scroll; }
    }
    layout {
      gaps 8
      default-column-width { proportion 0.5; }
    }
    prefer-no-csd
    binds {
      Mod+Return { spawn "alacritty"; }
      Mod+T { spawn "alacritty"; }
      Mod+E { spawn "thunar"; }
      Mod+D { spawn "fuzzel"; }
      Mod+L { spawn "kobold-lock"; }
      Mod+Q { close-window; }
      Mod+Left { focus-column-left; }
      Mod+Right { focus-column-right; }
      Mod+Up { focus-window-up; }
      Mod+Down { focus-window-down; }
      Mod+Shift+Left { move-column-left; }
      Mod+Shift+Right { move-column-right; }
      Mod+Shift+Up { move-window-up; }
      Mod+Shift+Down { move-window-down; }
      Mod+Page_Up { focus-workspace-up; }
      Mod+Page_Down { focus-workspace-down; }
      Mod+Shift+Page_Up { move-column-to-workspace-up; }
      Mod+Shift+Page_Down { move-column-to-workspace-down; }
      Mod+F { maximize-column; }
      Mod+Shift+F { fullscreen-window; }
      Mod+O { toggle-overview; }
      Mod+Shift+E { quit; }
      Print { screenshot; }
      XF86AudioRaiseVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05+" "-l" "1.0"; }
      XF86AudioLowerVolume allow-when-locked=true { spawn "wpctl" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.05-"; }
      XF86AudioMute allow-when-locked=true { spawn "wpctl" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
      XF86MonBrightnessUp { spawn "brightnessctl" "set" "+5%"; }
      XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }
    }
  '';

  environment.etc."xdg/noctalia/nixos.toml".text = ''
    [shell]
    polkit_agent = true

    [idle.behavior.lock]
    enabled = false

    [idle.behavior.screen-off]
    enabled = false
  '';

  environment.etc."xdg/autostart/kobold-noctalia.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Noctalia
    Exec=${koboldNoctalia}/bin/kobold-noctalia
    OnlyShowIn=niri;
    NoDisplay=true
  '';

  # Niri enables this by default; omit the optional GNOME credential daemon.
  services.gnome.gnome-keyring.enable = false;
  security.polkit.enable = true;
  services.upower.enable = true;

  # Lightweight file manager without installing an entire desktop environment.
  programs.thunar = {
    enable = true;
    plugins = with pkgs; [ thunar-volman ];
  };

  services.udisks2.enable = true;
  services.gvfs.enable = true; # Thunar mount/trash/removable-media integration.
  services.tumbler.enable = true;

  # ------------------------------------------------------------
  # AUDIO
  # ------------------------------------------------------------
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = false;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # ------------------------------------------------------------
  # SCREEN LOCKING
  # ------------------------------------------------------------
  security.pam.services.gtklock = { };
  security.pam.services.noctalia = { };

  # niri-session starts the XDG autostart target with the Wayland environment.
  environment.etc."xdg/autostart/kobold-idle.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Kobold Idle Lock
    Exec=${koboldIdle}/bin/kobold-idle
    OnlyShowIn=niri;
    NoDisplay=true
  '';

  # ------------------------------------------------------------
  # CONTAINERS — rootless-first
  # ------------------------------------------------------------
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    dockerSocket.enable = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.docker.enable = false;

  # ------------------------------------------------------------
  # VIRTUALIZATION — system libvirt / unprivileged QEMU
  # ------------------------------------------------------------
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    sshProxy = false;
    # Do not expose qemu-bridge-helper to user-session QEMU by default.
    allowedBridges = [ ];

    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false;
      swtpm.enable = true;

      # NixOS currently overrides libvirt's upstream mount-namespace default
      # with namespaces=[]. Restore the upstream isolation boundary here.
      # QEMU seccomp stays at libvirt's upstream default; no redundant override.
      verbatimConfig = ''
        namespaces = [ "mount" ]
      '';
    };
  };

  # ------------------------------------------------------------
  # USER — exactly one normal/human account
  # ------------------------------------------------------------
  users.mutableUsers = true;

  users.users.kobold = {
    isNormalUser = true;
    uid = 1000;
    description = "Kobold";
    home = "/home/kobold";
    createHome = true;
    shell = pkgs.fish;

    # Rootless Podman/Distrobox need subordinate UID/GID mappings. Let NixOS
    # allocate the standard 65536-ID range declaratively.
    autoSubUidGidRange = true;

    # Keep the human account minimally privileged. NetworkManager, device access
    # and qemu:///system administration are mediated by logind/polkit.
    extraGroups = [ "wheel" ];

    # Intentionally no password/hash in this file.
    # Set it locally after nixos-install, before first reboot:
    #   nixos-enter --root /mnt -c 'passwd kobold'
    # This password is used by sudo, Ly and the lock screen.
  };

  security.sudo = {
    execWheelOnly = true;
    wheelNeedsPassword = true;
    extraConfig = ''
      Defaults timestamp_timeout=5
      Defaults passwd_tries=3
    '';
  };

  # ------------------------------------------------------------
  # NIX — stable channel, no flakes / no experimental features
  # ------------------------------------------------------------
  nixpkgs.config.allowUnfree = false;

  nix = {
    settings = {
      sandbox = true;
      allowed-users = [ "root" "@wheel" ];
      trusted-users = [ "root" ];
      require-sigs = true;

      # Deliberately do not add experimental-features here.
      # No third-party substituters or trusted-public-keys are configured.
      keep-outputs = false;
      keep-derivations = false;
    };

    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
  };

  # Manual/staged upgrades are preferred on this laptop. Generations provide
  # rollback without requiring flakes.
  system.autoUpgrade.enable = false;

  # ------------------------------------------------------------
  # SERVICES — minimal host exposure
  # ------------------------------------------------------------
  services.openssh.enable = false;
  services.printing.enable = false;
  services.avahi.enable = false;
  services.fwupd.enable = true;
  services.smartd.enable = false;

  # Keep journald bounded on the 240 GB NVMe.
  services.journald.extraConfig = ''
    SystemMaxUse=300M
    SystemKeepFree=500M
    MaxRetentionSec=14day
  '';

  # ------------------------------------------------------------
  # APPLICATIONS / ADMIN / DEVSECOPS BASELINE
  # ------------------------------------------------------------
  programs.fish.enable = true;
  programs.firefox.enable = true;
  programs.virt-manager.enable = true;

  environment.systemPackages = with pkgs; [
    # Wayland UX
    noctalia
    koboldNoctalia
    koboldLock
    koboldIdle
    alacritty
    fuzzel
    swayidle
    gtklock
    xwayland-satellite
    wl-clipboard
    cliphist
    grim
    slurp
    satty
    brightnessctl
    playerctl
    pamixer
    pavucontrol
    libnotify
    xdg-utils

    # Core CLI / editing
    helix
    git
    git-lfs
    gh
    curl
    wget
    jq
    ripgrep
    fd
    bat
    fzf
    btop
    yazi
    tmux
    tree
    file
    rsync
    zip
    unzip
    p7zip
    gnupg
    age
    chezmoi
    just

    # Containers / image tooling
    distrobox
    buildah
    skopeo

    # Virtualization UI
    virt-viewer

    # Hardware / security / diagnostics
    lynis
    vulnix
    smartmontools
    nvme-cli
    ethtool
    lm_sensors
    powertop
    powerstat
    amdgpu_top
    config.boot.kernelPackages.cpupower
    pciutils
    usbutils
    libva-utils
    vulkan-tools
  ];

  # Flatpak is available as the isolation layer for GUI apps. Do not declare
  # Flathub as a root-owned remote here; add it per-user after login if desired.
  services.flatpak.enable = true;

  xdg.mime = {
    enable = true;
    defaultApplications = {
      "inode/directory" = [ "thunar.desktop" ];
    };
  };

  # ------------------------------------------------------------
  # QUALITY-OF-LIFE COMMANDS
  # ------------------------------------------------------------
  environment.shellAliases = {
    nx-test = "sudo nixos-rebuild test";
    nx-switch = "sudo nixos-rebuild switch";
    nx-boot = "sudo nixos-rebuild boot";
    nx-update = "sudo nixos-rebuild switch --upgrade";
    nx-rollback = "sudo nixos-rebuild switch --rollback";
    nx-gc = "sudo nix-collect-garbage --delete-older-than 14d";
    nx-generations = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";
    temps = "sensors";
    lock = "kobold-lock";
  };

  # Fresh NixOS 26.05 installation. Do not bump this on ordinary upgrades.
  system.stateVersion = "26.05";
}
