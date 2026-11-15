# Shared by every host here: a Proxmox VM image, SSH, nix, monitoring.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [ "${modulesPath}/virtualisation/proxmox-image.nix" ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "26.05";

  # Shape of the VM in the .vma image; NICs are set per host.
  proxmox = {
    qemuConf = {
      name = config.networking.hostName;
      cores = 2;
      # Enough for `nixos-rebuild` to evaluate and build on the box (see deploy.sh).
      memory = 2048;
      diskSize = "8192";
    };
    cloudInit.enable = false;
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    # https://github.com/Arsenikki.keys
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMDW9GdpHKXpPspO9CzvTx/6P/zELvO1Di5+GnGgd03e"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrNGfpo8ySpfpg/cwSHwT7wkHhH+zs/C6EEfDJSTZxf"
    # paseo-generic (1Password `paseo-ssh`), the same key that has root on the Proxmox nodes.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+pln2J9FmCVKkhts28Y+cWuQeAw0YnVxtZyw2xRs1r"
  ];

  # sops-nix decrypts with the host's SSH key (converted to age); add its age
  # recipient to .sops.yaml after the first boot. See README.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.prometheus.exporters.node = {
    enable = true;
    enabledCollectors = [ "systemd" ];
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    min-free = 1024 * 1024 * 1024;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [
    conntrack-tools
    dig
    ethtool
    tcpdump
  ];

  time.timeZone = "Europe/London";
  i18n.defaultLocale = "en_GB.UTF-8";
}
