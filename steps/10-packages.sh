#!/bin/bash
# Repo packages + AUR packages (garm-bin, garm-provider-incus-bin).

log "installing repo packages"
pacman -S --needed --noconfirm incus btrfs-progs git base-devel

aur_install() {
    local pkg=$1
    if pacman -Qi "$pkg" &>/dev/null; then
        log "$pkg already installed"
        return 0
    fi
    if command -v paru &>/dev/null; then
        as_user paru -S --noconfirm "$pkg"
    elif command -v yay &>/dev/null; then
        as_user yay -S --noconfirm "$pkg"
    else
        log "no AUR helper — building $pkg with makepkg as $SUDO_USER"
        local bdir
        bdir=$(as_user mktemp -d)
        as_user git clone "https://aur.archlinux.org/$pkg.git" "$bdir/$pkg"
        (cd "$bdir/$pkg" && as_user makepkg -s --noconfirm)
        pacman -U --noconfirm "$bdir/$pkg"/*.pkg.tar.zst
        rm -rf "$bdir"
    fi
}

aur_install garm-bin
aur_install garm-provider-incus-bin
