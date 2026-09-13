#!/bin/bash
# Repo packages + AUR packages (garm-bin, garm-provider-incus-bin).

log "installing repo packages"
pacman -S --needed --noconfirm incus btrfs-progs

# Only the controller builds/runs garm and the provider binary, and only it
# needs python (step 70) and the AUR build toolchain.
if [[ $HOST_ROLE == controller ]]; then
    pacman -S --needed --noconfirm git base-devel python
fi

aur_install() {
    local pkg=$1 bdir pkgfile deps
    if pacman -Qi "$pkg" &>/dev/null; then
        log "$pkg already installed"
        return 0
    fi
    # setup.sh runs as root, but makepkg refuses to run as root and AUR helpers
    # (paru/yay) invoke sudo again from the dropped-privilege context. That
    # nested sudo runs in a different tty/session than the login sudo, so it
    # cannot reuse the cached credentials and re-prompts on every pacman call.
    # Avoid it: read the deps and install them as root here (no nested sudo),
    # build with makepkg as $SUDO_USER *without* -s so makepkg never calls sudo
    # itself, then install the built package with pacman -U as root.
    log "building $pkg with makepkg as $SUDO_USER"
    bdir=$(as_user mktemp -d)
    as_user git clone -q "https://aur.archlinux.org/$pkg.git" "$bdir/$pkg"
    # Single quotes are deliberate: the arrays must expand inside the inner
    # shell (running as the user, after sourcing the PKGBUILD), not out here.
    # shellcheck disable=SC2016
    deps=$(cd "$bdir/$pkg" && as_user bash -c 'source ./PKGBUILD; echo "${depends[*]} ${makedepends[*]}"')
    if [[ -n ${deps// /} ]]; then
        # shellcheck disable=SC2086
        pacman -S --needed --noconfirm --asdeps $deps
    fi
    (cd "$bdir/$pkg" && as_user makepkg --noconfirm)
    for pkgfile in "$bdir/$pkg"/*.pkg.tar.zst; do
        [[ $pkgfile == *-debug-* ]] && continue
        pacman -U --noconfirm "$pkgfile"
    done
    rm -rf "$bdir"
}

if [[ $HOST_ROLE == controller ]]; then
    aur_install garm-bin
    aur_install garm-provider-incus-bin
fi
