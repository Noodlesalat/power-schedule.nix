{
  description = "Ein NixOS Modul für automatisches Starten und Herunterfahren via RTC";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.powerSchedule = import ./module.nix;

    nixosModules.default = self.nixosModules.powerSchedule;
  };
}
