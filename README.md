
# Power Schedule NixOS Module

This module allows you to define automatic startup and shutdown schedules for your NixOS systems. It utilizes `systemd` timers to schedule graceful shutdowns and sets hardware RTC alarms via `rtcwake` to automatically wake the system up.

## Installation / Usage

### With Flakes

Add the repository to the `inputs` of your target host's `flake.nix`:

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  power-schedule.url = "github:Noodlesalat/power-schedule.nix";
};

outputs = { self, nixpkgs, power-schedule, ... }: {
  nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ./configuration.nix
      power-schedule.nixosModules.default
    ];
  };
};
```

### Without Flakes

If you are not using flakes, you can import the module directly in your `configuration.nix` using `fetchTarball`:

```nix
imports = [
  (fetchTarball "https://github.com/Noodlesalat/power-schedule.nix/archive/main.tar.gz")
];
```

## Example Configuration

Add the following to your NixOS configuration (e.g., `configuration.nix`) to set up a schedule:

```nix
services.powerSchedule = {
  enable = true;
  events = [
    # Wake up at 07:30 from Monday to Friday
    { action = "start"; days = [ "Mon" "Tue" "Wed" "Thu" "Fri" ]; time = "07:30"; }
    
    # Shut down at 18:00 from Monday to Friday
    { action = "shutdown"; days = [ "Mon" "Tue" "Wed" "Thu" "Fri" ]; time = "18:00"; }
  ];
};
```

## Available Options

Here is a full list of all configuration options provided by this module:

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `services.powerSchedule.enable` | `boolean` | `false` | Enables the automatic power schedule service. |
| `services.powerSchedule.events` | `list of objects` | `[]` | A list of events defining when the machine should start or shut down. |

### Event Object Details

Each item in the `events` list is an object containing the following properties:

| Property | Type | Valid Values / Format | Description |
| :--- | :--- | :--- | :--- |
| `action` | `string` | `"start"` or `"shutdown"` | Determines whether this event turns the machine on (`start`) or turns it off (`shutdown`). |
| `days` | `list of strings` | `"Mon"`, `"Tue"`, `"Wed"`, `"Thu"`, `"Fri"`, `"Sat"`, `"Sun"` | A list of weekdays on which this specific event should be executed. |
| `time` | `string` | `"HH:MM"` (e.g., `"08:30"`) | The exact time of day in 24-hour format. Must be two digits for hours and two for minutes. |

## How it works

- **Shutdowns:** The module creates native `systemd` timers for every `"shutdown"` event you define. Once triggered, it safely powers off the system using `systemctl poweroff`.
- **Startups:** During the shutdown process (triggered by systemd targets like `halt.target` or `poweroff.target`), a custom script runs. It parses all `"start"` events, calculates the timestamp of the *next upcoming* start date, and programs the hardware clock using `rtcwake -m no`
