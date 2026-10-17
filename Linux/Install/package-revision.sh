#!/usr/bin/env bash
#
# Which package revision applies; the same for deb, rpm and pacman.
#
#     package-revision.sh [explicit]
#
# **Why it comes from the PKGBUILD.** When the same version is released again
# with a fix, the revision must increase, otherwise apt, dnf and pacman see no
# update. As a workflow input alone (default 1), every run on a tag would use
# 1 and a rebuild of the same version would reach nobody. `pkgrel` in the
# PKGBUILD is bumped with the build number anyway, so the value comes from
# there unless someone passes a different one explicitly.
set -euo pipefail
if [ -n "${1:-}" ]; then echo "$1"; exit 0; fi
state=$(sed -n 's/^pkgrel=\([0-9][0-9]*\)$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/PKGBUILD")
echo "${state:-1}"
