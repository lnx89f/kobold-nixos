{ config, pkgs, lib, ... }:

let
  # One lock command works across all three compositors.
  # Hyprland uses its native locker; Sway and Niri use swaylock.
  koboldLock = pkgs.writeShellApplication {
    name = "kobold-lock";
    text = ''
      desktop="''${XDG_CURRENT_DESKTOP:-}"
      case "$desktop" in
        *Hyprland*|*hyprland*)
          exec ${pkgs.hyprlock}/bin/hyprlock
          ;;
        *)
          exec ${pkgs.swaylock}/bin/swaylock -f
          ;;
      esac
    '';
  };

  # Session-aware idle/lock policy. This is system policy, while visual
  # compositor configuration remains mutable in ~/.config.
  koboldIdle = pkgs.writeShellApplication {
    name = "kobold-idle";
    text = ''
      desktop="''${XDG_CURRENT_DESKTOP:-}"
      case "$desktop" in
        *Hyprland*|*hyprland*)
          exec ${pkgs.hypridle}/bin/hypridle --config /etc/xdg/hypr/hypridle.conf
          ;;
        *niri*|*Niri*)
          exec ${pkgs.swayidle}/bin/swayidle -w \
            timeout 600 '${koboldLock}/bin/kobold-lock' \
            timeout 660 '${pkgs.niri}/bin/niri msg action power-off-monitors' \
            before-sleep '${koboldLock}/bin/kobold-lock'
          ;;
        *)
          exec ${pkgs.swayidle}/bin/swayidle -w \
            timeout 600 '${koboldLock}/bin/kobold-lock' \
            timeout 660 '${pkgs.sway}/bin/swaymsg "output * power off"' \
            resume '${pkgs.sway}/bin/swaymsg "output * power on"' \
            before-sleep '${koboldLock}/bin/kobold-lock'
          ;;
      esac
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
    TERMINAL = "foot";
    EDITOR = "hx";
    VISUAL = "hx";
    LIBVIRT_DEFAULT_URI = "qemu:///system";
  };

  # ------------------------------------------------------------
  # WAYLAND DESKTOPS — Sway + Niri + Hyprland
  # ------------------------------------------------------------
  programs.sway = {
    enable = true;
    xwayland.enable = true;
  };

  programs.niri = {
    enable = true;
    # GTK portal handles file choosing; do not pull Nautilus just for this.
    useNautilus = false;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
    # Hyprland is launched through start-hyprland and uses its native systemd
    # session integration. Avoid an extra UWSM layer on this single-user host.
    withUWSM = false;
  };

  # Autologin once into Hyprland. After logout, greetd stays at the TUI greeter and
  # lets you choose Hyprland, Sway or Niri from the registered Wayland sessions.
  services.greetd = {
    enable = true;
    useTextGreeter = true;

    settings = {
      initial_session = {
        # Use Hyprland's supported launcher rather than invoking the compositor
        # binary directly; it prepares the session environment correctly.
        command = "${config.programs.hyprland.package}/bin/start-hyprland";
        user = "kobold";
      };

      default_session = {
        command = lib.concatStringsSep " " [
          "${pkgs.tuigreet}/bin/tuigreet"
          "--time"
          "--remember"
          "--remember-user-session"
          "--asterisks"
          "--greeting Kobold"
          "--sessions /run/current-system/sw/share/wayland-sessions"
        ];
        user = "greeter";
      };
    };
  };

  # Wayland session modules already enable the necessary portal infrastructure.
  # Keep only the extra GTK portal explicitly available for generic applications.
  xdg.portal.enable = true;

  # Polkit is required by libvirt, fwupd and normal privileged desktop actions.
  security.polkit.enable = true;

  # One lightweight graphical Polkit agent. XDG autostart from the WM modules
  # starts it in Sway/Niri/Hyprland sessions.
  environment.systemPackages = with pkgs; [
    mate-polkit
  ];

  environment.etc."xdg/autostart/kobold-polkit.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Kobold Polkit Agent
    Exec=${pkgs.mate-polkit}/libexec/polkit-mate-authentication-agent-1
    NoDisplay=true
    X-GNOME-Autostart-enabled=true
  '';

  # Network tray applet starts automatically in graphical sessions.
  programs.nm-applet = {
    enable = true;
    indicator = true;
  };

  services.blueman.enable = true;

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
  # Both PAM services authenticate against the kobold account password.
  security.pam.services.swaylock = { };
  security.pam.services.hyprlock = { };

  # Start the appropriate idle daemon in every compositor session. NixOS'
  # Wayland-session modules run XDG autostart entries for bare WMs.
  environment.etc."xdg/autostart/kobold-idle.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Kobold Idle Lock
    Exec=${koboldIdle}/bin/kobold-idle
    NoDisplay=true
    X-GNOME-Autostart-enabled=true
  '';

  # Minimal native Hyprland lock screen. A user config in ~/.config/hypr/
  # overrides this system fallback automatically.
  environment.etc."xdg/hypr/hyprlock.conf".text = ''
    general {
        hide_cursor = true
        immediate_render = true
    }

    background {
        monitor =
        color = rgba(111111ff)
        blur_passes = 0
    }

    input-field {
        monitor =
        size = 260, 52
        outline_thickness = 2
        outer_color = rgb(555555)
        inner_color = rgb(111111)
        font_color = rgb(eeeeee)
        placeholder_text = Password...
        fail_text = $FAIL ($ATTEMPTS)
        position = 0, 0
        halign = center
        valign = center
    }
  '';

  environment.etc."xdg/hypr/hypridle.conf".text = ''
    general {
        lock_cmd = ${koboldLock}/bin/kobold-lock
        before_sleep_cmd = ${pkgs.systemd}/bin/loginctl lock-session
        after_sleep_cmd = ${pkgs.hyprland}/bin/hyprctl dispatch dpms on
        ignore_dbus_inhibit = false
        ignore_systemd_inhibit = false
    }

    listener {
        timeout = 600
        on-timeout = ${pkgs.systemd}/bin/loginctl lock-session
    }

    listener {
        timeout = 660
        on-timeout = ${pkgs.hyprland}/bin/hyprctl dispatch dpms off
        on-resume = ${pkgs.hyprland}/bin/hyprctl dispatch dpms on
    }
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
    # This password is used by sudo, tuigreet after logout and the lock screen.
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

  environment.systemPackages = with pkgs; [
    # Wayland UX
    koboldLock
    koboldIdle
    foot
    waybar
    fuzzel
    mako
    swaybg
    swayidle
    swaylock
    hypridle
    hyprlock
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
    virt-manager
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
