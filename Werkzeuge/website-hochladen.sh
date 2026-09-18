#!/bin/zsh
# Abgeloest durch website-hochladen.py. Die curl-Fassung meldete sich nach jedem
# Fehler fuer die naechste Datei neu an; All-Inkl sperrte daraufhin mit 530.
exec "${0:A:h}/website-hochladen.py" "$@"
