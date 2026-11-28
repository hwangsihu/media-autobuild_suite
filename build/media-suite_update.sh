#!/bin/bash
# shellcheck disable=SC2086,SC1091

while true; do
    case $1 in
    --update=*)
        update="${1#*=}"
        shift
        ;;
    --CC=*)
        CC="${1#*=}"
        shift
        ;;
    --)
        shift
        break
        ;;
    -*)
        echo "Error, unknown option: '$1'."
        exit 1
        ;;
    *) break ;;
    esac
done

# start suite update
if [[ -d "/trunk/build" ]]; then
    cd "/trunk/build" || exit 1
else
    cd "$(cygpath -w /)../build" || exit 1
fi
[[ -f media-suite_helper.sh ]] && source media-suite_helper.sh
[[ -f media-suite_deps.sh ]] && source media-suite_deps.sh
[[ -f media-suite_deps_extra.sh ]] && source media-suite_deps_extra.sh

# --------------------------------------------------
# update suite
# --------------------------------------------------

if [[ $update == "yes" ]]; then
    echo
    echo "-------------------------------------------------------------------------------"
    echo "checking if suite has been updated..."
    echo "-------------------------------------------------------------------------------"
    echo

    if [[ ! -d ../.git ]] && command -v git > /dev/null; then
        if ! git clone "${SOURCE_REPO_MABS:-https://github.com/m-ab-s/media-autobuild_suite.git}" ab-git; then
            git -C ab-git fetch
        fi
        cp -fr ab-git/.git ..
    fi
    cd_safe ..
    if [[ -d .git ]]; then
        if [[ -n "$(git diff --name-only)" ]]; then
            diffname="$(date +%F-%H.%M.%S)"
            git diff --diff-filter=M >> "build/user-changes-${diffname}.diff"
            echo "Your changes have been exported to build/user-changes-${diffname}.diff."
            git reset --hard "@{upstream}"
        fi
        git fetch -t
        oldHead=$(git rev-parse HEAD)
        git reset --hard "@{upstream}"
        newHead=$(git rev-parse HEAD)
        if [[ $oldHead != "$newHead" ]]; then
            echo "Suite has been updated!"
            echo "If you had an issue try running the suite again before reporting."
        else
            echo "Suite up-to-date."
            echo "If you had an issue, please report it in GitHub."
        fi
        read -r -t 15 -p '<Enter> to close' ret
    fi
fi # end suite update

echo
echo "-------------------------------------------------------------------------------"
echo "Updating pacman packages..."
echo "-------------------------------------------------------------------------------"
echo

pacman -Sy --ask=20 --noconfirm
do_unhide_all_sharedlibs

overwrite=(--overwrite "/mingw64/*" --overwrite "/clang64/*" --overwrite "/ucrt64/*"
    --overwrite "/usr/*")
# a -Su with any of these pending makes MSYS2's pacman kill all MSYS2 processes, this script included
core_pkgs='^(bash|filesystem|mintty|msys2-runtime(-.*)?|pacman|pacman-mirrors)$'
updates=()
core_updates=()
while read -r pkg _ _ _ ignored; do
    [[ -z $pkg || $ignored == "[ignored]" ]] && continue
    if [[ $pkg =~ $core_pkgs ]]; then
        core_updates+=("$pkg")
    else
        updates+=("$pkg")
    fi
done < <(pacman -Qu 2> /dev/null)

if ((${#updates[@]} + ${#core_updates[@]})); then
    echo "-------------------------------------------------------------------------------"
    echo "Updating msys2 system and installed packages..."
    echo "-------------------------------------------------------------------------------"
fi
if ((${#core_updates[@]})); then
    echo "${core_updates[*]}" > /build/update_core
    ((${#updates[@]})) && pacman -S --noconfirm --needed "${overwrite[@]}" "${updates[@]}"
else
    # do an overall installation for potential downgrades
    pacman -Suu --noconfirm "${overwrite[@]}"
fi

# -------------------------------------------------------------------------------
# check packages
# -------------------------------------------------------------------------------

extract_pkg_prefix() (
    . shell "$1"
    echo "$MINGW_PACKAGE_PREFIX-"
)

if [[ -f /etc/pac-base.pk && -f /etc/pac-mingw.pk ]]; then
    new=$(mktemp)
    old=$(mktemp)
    echo
    echo "-------------------------------------------------------------------------------"
    echo "Checking pacman packages..."
    echo "-------------------------------------------------------------------------------"
    echo
    case $CC in
    *clang) prefix=$(extract_pkg_prefix clang64) ;;
    *) prefix=$(extract_pkg_prefix ucrt64) ;;
    esac
    {
        pacman -Sgg | sed 's/^/G /'
        pacman -Slq | sed 's/^/P /'
        dos2unix -O /etc/pac-mingw.pk /etc/pac-mingw-extra.pk 2> /dev/null | sed "/^\s*$/d;s/^/W $prefix/"
        dos2unix -O /etc/pac-base.pk /etc/pac-msys-extra.pk 2> /dev/null | sed '/^\s*$/d;s/^/W /'
    } | awk '
        $1 == "G" { members[$2] = members[$2] " " $3; next }
        $1 == "P" { known[$2] = 1; next }
        $1 == "W" {
            if ($2 in members) {
                n = split(members[$2], pkgs, " ")
                for (i = 1; i <= n; i++) print pkgs[i]
            } else if ($2 in known) print $2
            else print "Package " $2 " was not found in the repos, skipping it." > "/dev/stderr"
        }' | LC_ALL=C sort -u > "$new"
    pacman -Qqe | LC_ALL=C sort -u > "$old"
    mapfile -t install < <(LC_ALL=C comm -13 "$old" "$new")
    mapfile -t uninstall < <(LC_ALL=C comm -23 "$old" "$new")

    if ((${#install[@]})); then
        mapfile -t missing < <(pacman -Qq | LC_ALL=C sort -u | LC_ALL=C comm -13 - "$new")
        if ((${#missing[@]})); then
            echo "You're missing some packages!"
            echo "Proceeding with installation..."
            pacman -S --noconfirm --needed "${missing[@]}"
        fi
        pacman -D --asexplicit "${install[@]}" > /dev/null
    fi
    ((${#uninstall[@]})) && pacman --noconfirm -D --asdeps "${uninstall[@]}" > /dev/null
    mapfile -t orphans < <(pacman -Qqdtt)
    if [[ ${#orphans[@]} -gt 0 ]]; then
        echo
        echo "-------------------------------------------------------------------------------"
        echo "You have more packages than needed!"
        echo "Do you want to remove them?"
        echo "-------------------------------------------------------------------------------"
        echo
        echo "Remove:"
        printf '%s\n' "${orphans[@]}"
        while true; do
            read -r -p "remove packs [y/n]? " yn || break
            case $yn in
            [Yy]*)
                pacman -Rns --noconfirm "${orphans[@]}"
                break
                ;;
            [Nn]*)
                break
                ;;
            *) echo "Please answer yes or no" ;;
            esac
        done
    fi
    rm -f /etc/pac-{base,mingw}.pk "$new" "$old"
fi

if [[ -d "/trunk" ]]; then
    cd "/trunk" || exit 1
else
    cd_safe "$(cygpath -w /).."
fi

do_hide_all_sharedlibs

echo "-------------------------------------------------------------------------------"
echo "Updates finished."
echo "-------------------------------------------------------------------------------"

sleep 2

exit
