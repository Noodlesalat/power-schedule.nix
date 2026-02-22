{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.powerSchedule;

  scheduleEventOpts = types.submodule {
    options = {
      action = mkOption {
        type = types.enum [ "start" "shutdown" ];
        description = "Aktion: start oder shutdown";
      };
      days = mkOption {
        type = types.listOf (types.enum [ "Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun" ]);
        description = "Wochentage";
      };
      time = mkOption {
        type = types.strMatching "[0-9]{2}:[0-9]{2}";
        description = "Uhrzeit (HH:MM)";
      };
    };
  };

  daysToSystemd = days: concatStringsSep "," days;
  
  shutdownEvents = filter (e: e.action == "shutdown") cfg.events;
  startEvents = filter (e: e.action == "start") cfg.events;

  # -- Das verbesserte Skript --
  calculateNextWakeup = pkgs.writeShellScriptBin "calculate-next-wakeup" ''
    # Pfad für notwendige Tools setzen
    export PATH=$PATH:${makeBinPath [ pkgs.util-linux pkgs.systemd pkgs.coreutils pkgs.gawk pkgs.gnugrep ]}

    echo "[PowerSchedule] Starting wake-up calculation..."

    # 1. Konfiguration laden (Nix injiziert hier die Daten in ein Bash-Array)
    # Das macht den Code unten sauber, da keine Nix-Syntax mehr im Logik-Teil steht.
    declare -a schedules=(
      ${concatMapStrings (event: ''"${daysToSystemd event.days} *-*-* ${event.time}:00" '') startEvents}
    )

    if [ ''${#schedules[@]} -eq 0 ]; then
      echo "[PowerSchedule] No start events configured. Doing nothing."
      exit 0
    fi

    # 2. Nächsten Zeitpunkt berechnen
    min_epoch=0

    for spec in "''${schedules[@]}"; do
      # systemd-analyze berechnet das nächste Vorkommen
      # Wir nutzen 'timestamp', um sicherzustellen, dass wir das Datum sauber parsen können
      echo "[PowerSchedule] Checking schedule: $spec"
      
      # Ausgabe filtern nach "Next elapse:"
      next_date_str=$(systemd-analyze calendar "$spec" | grep "Next elapse:" | sed 's/.*Next elapse: //')

      if [ -n "$next_date_str" ]; then
        # Datum in Unix-Timestamp wandeln
        this_epoch=$(date -d "$next_date_str" +%s)
        echo "  -> Next occurrence: $next_date_str ($this_epoch)"

        # Ist dies der früheste Zeitpunkt?
        if [ "$min_epoch" -eq 0 ] || [ "$this_epoch" -lt "$min_epoch" ]; then
          min_epoch=$this_epoch
        fi
      fi
    done

    # 3. RTC Timer setzen (mit Retry-Logik)
    if [ "$min_epoch" -ne 0 ]; then
      wake_date=$(date -d @$min_epoch)
      echo "------------------------------------------------"
      echo "[PowerSchedule] TARGET WAKEUP: $wake_date"
      echo "------------------------------------------------"

      # Retry Schleife, falls /dev/rtc0 busy ist
      max_retries=10
      count=0
      success=0

      while [ $count -lt $max_retries ]; do
        # rtcwake versuchen
        # -m no: Setzt nur den Timer, fährt nicht sofort runter (das macht systemd gleich)
        if rtcwake -m no -t "$min_epoch"; then
          echo "[PowerSchedule] Success: RTC alarm set."
          success=1
          break
        else
          echo "[PowerSchedule] Warning: Failed to set RTC (Device busy?). Retrying in 1s... ($((count+1))/$max_retries)"
          sleep 1
          count=$((count + 1))
        fi
      done

      if [ $success -eq 0 ]; then
        echo "[PowerSchedule] ERROR: Could not set RTC alarm after $max_retries attempts."
        exit 1
      fi

    else
      echo "[PowerSchedule] No future dates found (configuration error?)."
    fi
  '';

in
{
  options.services.powerSchedule = {
    enable = mkEnableOption "Automatic Power Schedule";
    events = mkOption {
      type = types.listOf scheduleEventOpts;
      default = [];
      description = "List of power schedule events.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.power-schedule-shutdown = {
      description = "Power Schedule Shutdown Execution";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl poweroff";
      };
    };

    systemd.timers = let
      mkTimer = index: event: {
        name = "power-schedule-shutdown-${toString index}";
        value = {
          description = "Shutdown Timer ${toString index}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "${daysToSystemd event.days} *-*-* ${event.time}:00";
            Unit = "power-schedule-shutdown.service";
          };
        };
      };
    in listToAttrs (imap0 (i: e: mkTimer i e) shutdownEvents);

    systemd.services.power-schedule-set-wakeup = {
      description = "Set RTC wakeup based on schedule";
      
      before = [ "shutdown.target" "halt.target" "poweroff.target" ];
      wantedBy = [ "shutdown.target" "halt.target" "poweroff.target" ];
      
      unitConfig.DefaultDependencies = false;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${calculateNextWakeup}/bin/calculate-next-wakeup";
        RemainAfterExit = true;
        TimeoutSec = "30s";
      };
    };
  };
}
