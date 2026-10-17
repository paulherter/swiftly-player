#!/bin/zsh
# Superseded by website-upload.py. The curl version logged in again for the next
# file after every error, and the host then blocked the account with a 530.
exec "${0:A:h}/website-upload.py" "$@"
