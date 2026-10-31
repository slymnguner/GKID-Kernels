#!/usr/bin/env bash

declare -A ANDROID_RELEASE_FOR_KVER=(
  ["5.10"]="12"
  ["5.15"]="13"
  ["6.1"]="14"
  ["6.6"]="15"
  ["6.12"]="16"
)

declare -A GKI_SUSFS_COMMIT=(
#  ["6.1"]="153f88df3be2501d2d33364f8fe05247aecb3cef"
#  ["6.6"]="3f0b811b2e105afd8dc858cd71389090e01f404b"
#  ["6.12"]="fb58aef70a9c2aca8f0f85fba14017af94c4e789"
)

android_release_for_version() {
  echo "${ANDROID_RELEASE_FOR_KVER[$1]:-unknown}"
}

kernel_version_lt() {
  [ "$1" = "$2" ] && return 1
  local IFS=.
  local -a a=($1) b=($2)
  local i max=${#a[@]}
  [ ${#b[@]} -gt "$max" ] && max=${#b[@]}
  for ((i=0; i<max; i++)); do
    local ai="${a[i]:-0}"
    local bi="${b[i]:-0}"
    if ((10#$ai < 10#$bi)); then return 0; fi
    if ((10#$ai > 10#$bi)); then return 1; fi
  done
  return 1
}

kernel_version_eq() {
  [ "$1" = "$2" ] || return 1
  return 0
}

susfs_included() {
  [ "$KSU_SUSFS" == "true" ]
  return $?
}

simplify_gh_url() {
  local URL="$1"
  echo "$URL" | sed "s|https://github.com/||g" | sed "s|\.git$||"
}

config() {
  [ -n "${KSRC:-}" ] || { error "KSRC unset, cannot run config"; return 1; }
  [ -f "${DEFCONFIG_FILE:-}" ] || { error "DEFCONFIG_FILE unset or missing: '${DEFCONFIG_FILE:-}'"; return 1; }
  "$KSRC/scripts/config" --file "$DEFCONFIG_FILE" "$@"
}

log() {
  echo -e "[*] $*"
}
info() { log "$@"; }

success() {
  echo -e "[+] $*"
}

warning() {
  echo -e "[!] $*"
}

error() {
  echo -e "[-] $*"
}

retry() {
    local max_attempts=5
    local delay=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi

        error "Command failed (attempt $attempt/$max_attempts): $*"
        log "Retrying in ${delay}s..."
        sleep $delay
        delay=$((delay + 1))
        attempt=$((attempt + 1))
    done

    error "Command failed after $max_attempts attempts: $*" >&2
    return 1
}

curl() {
    command -v curl >/dev/null || { error "curl not installed"; return 127; }
    retry command curl "$@"
}
wget() {
    command -v wget >/dev/null || { error "wget not installed"; return 127; }
    retry command wget "$@"
}

bash() {
    case "$*" in

        *curl*|*wget*|*git*clone*|*git*fetch*|*git*pull*|*git*push*|*git*ls-remote*|*git*submodule*)
            retry command bash "$@"
            ;;
        *)
            command bash "$@"
            ;;
    esac
}

git() {
    local args=("$@")
    local idx=0
    while [ $idx -lt ${#args[@]} ]; do
        case "${args[$idx]}" in
            -C|-c|--git-dir|--work-tree|--exec-path|--namespace|--config-env)
                idx=$((idx+2))
                ;;
            -*)
                idx=$((idx+1))
                ;;
            *)
                break
                ;;
        esac
    done
    local cmd="${args[$idx]:-}"
    case "$cmd" in
        clone|fetch|pull|push|ls-remote|submodule)
            retry command git "${args[@]}"
            ;;
        *)
            command git "${args[@]}"
            ;;
    esac
}

export -f retry curl git wget bash
export -f error log info success warning

generate_gh_changelog() {
    local repo="$1"
    local branch="$2"
    local count="${3:-5}"
    local output="$4"

    if ! gh api "repos/${repo}/commits?sha=${branch}&per_page=${count}" \
            --jq '.[] | "- [" + .sha[0:7] + "](" + .html_url + ") " + (.commit.message | split("\n")[0])' \
            > "$output" 2>/dev/null; then
        warning "changelog API failed for $repo@$branch"
        echo "(changelog unavailable for $repo@$branch)" > "$output"
        return 0
    fi
}

apply_patch_file() {
    local patch="$1"
    local patch_data=""

    if [[ -n "$patch" ]]; then
        if [[ ! -f "$patch" ]]; then
            error "patch file not found: $patch"
            return 1
        fi
        patch_data=$(cat "$patch")
        info "Applying: $(basename "$patch")"
    else
        patch_data=$(cat)
        info "Applying patch from stdin"
    fi

    [[ -z "$patch_data" ]] && { error "No patch data"; return 1; }

    if echo "$patch_data" | git apply --check - 2>/dev/null; then
        if echo "$patch_data" | git apply - 2>/dev/null; then
            success "Applied patch successfully"
            return 0
        fi
    fi

    warning "git apply failed, trying patch with fuzz"

    if ! echo "$patch_data" | patch -p1 --fuzz=3 --dry-run 2>/dev/null; then
        warning "Skipping: patch does not apply"
        return 1
    fi

    if echo "$patch_data" | patch -p1 --fuzz=3 2>/dev/null; then
        success "Applied patch with fuzz"
        return 0
    else
        error "Failed to apply patch"
        return 1
    fi
}

build_and_install_pahole() {
    local pahole_dir="$HOME/.local/src/pahole"
    local install_prefix="$HOME/.local"
    local bin_dir="$install_prefix/bin"
    local lib_dir="$install_prefix/lib"
    local start_dir
    start_dir="$(pwd)"

    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
    export PATH="$bin_dir:$PATH"
    export LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    mkdir -p "$bin_dir" "$CCACHE_DIR"

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get remove -y --purge dwarves pahole 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true
        hash -r
    fi

    local missing=()
    for pkg in cmake libdw-dev libelf-dev zlib1g-dev; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} )); then
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}" || {
            error "failed to install build deps: ${missing[*]}"
            return 1
        }
    fi

    if [[ ! -d "$pahole_dir/.git" ]]; then
        rm -rf "$pahole_dir"
        git clone --depth=1 https://git.kernel.org/pub/scm/devel/pahole/pahole.git "$pahole_dir" || {
            error "failed to clone pahole"
            return 1
        }
    else
        git -C "$pahole_dir" fetch --depth=1 origin master || {
            error "failed to fetch pahole updates"
            return 1
        }
        git -C "$pahole_dir" reset --hard origin/master || {
            error "failed to reset pahole to origin/master"
            return 1
        }
    fi

    local build_dir="$pahole_dir/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir" || return 1

    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_prefix" \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_INSTALL_RPATH="$lib_dir" \
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
        -D__LIB=lib \
        .. || {
        error "cmake failed"
        cd "$start_dir" || true
        return 1
    }

    make -j"$(nproc)" || {
        error "pahole build failed"
        cd "$start_dir" || true
        return 1
    }

    make install || {
        error "pahole install failed"
        cd "$start_dir" || true
        return 1
    }

    cd "$start_dir" || { error "cd back after pahole install failed"; return 1; }

    hash -r
    if ! command -v pahole >/dev/null 2>&1; then
        error "pahole not found in PATH after install"
        return 1
    fi
    if ! pahole --version >/dev/null 2>&1; then
        error "pahole found but fails to run (check LD_LIBRARY_PATH/rpath)"
        return 1
    fi

    success "pahole $(pahole --version | head -1) installed to $bin_dir"
    return 0
}

apply_susfs_patches() {
    log "Applying SUSFS patches"

    [ -d "$SUSFS_PATCHES/fs" ] || { error "SUSFS fs patch dir missing: $SUSFS_PATCHES/fs"; return 1; }
    [ -d "$SUSFS_PATCHES/include/linux" ] || { error "SUSFS include patch dir missing: $SUSFS_PATCHES/include/linux"; return 1; }
    cp -R "$SUSFS_PATCHES/fs/." ./fs/ || { error "failed to copy SUSFS fs patches"; return 1; }
    cp -R "$SUSFS_PATCHES/include/linux/." ./include/linux/ || { error "failed to copy SUSFS include patches"; return 1; }

    if [ "$SUSFS_PATCH" = "gki-android14-6.1" ]; then
      local _susfs_pwd="$PWD"
      cd "$SUSFS_DIR" || { error "cd SUSFS_DIR failed"; return 1; }
      apply_patch_file "$KERNEL_PATCHES/susfs/susfs_fs_namespace_fix.patch" || true
      cd "$_susfs_pwd" || { error "cd back to KSRC failed"; return 1; }
    fi

    _susfs_core="$SUSFS_PATCHES/50_add_susfs_in_${SUSFS_PATCH}.patch"
    [ -f "$_susfs_core" ] || { error "SuSFS core patch missing: $_susfs_core"; return 1; }
    if ! patch -p1 --fuzz=3 < "$_susfs_core"; then
        error "SuSFS core patch failed: $_susfs_core"
        return 1
    fi

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h 2>/dev/null | cut -d' ' -f3 | sed 's/"//g')
    if [ -z "$SUSFS_VERSION" ]; then
        warning "SUSFS_VERSION not detected in include/linux/susfs.h"
        SUSFS_VERSION="unknown"
    fi
    echo "SUSFS_VERSION=$SUSFS_VERSION" >> "${GITHUB_ENV:-/dev/null}"
}

clone_susfs() {
    DEPTH=${1:-1}
    local pin="${GKI_SUSFS_COMMIT[$KERNEL_VERSION]:-}"

    if [ ! -d "$SUSFS_DIR" ]; then
        if [ -n "$pin" ]; then
            log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH) to pin commit $pin"
            git clone -q --single-branch -b "$SUSFS_BRANCH" "$SUSFS_URL" "$SUSFS_DIR" || {
                error "susfs clone failed: $SUSFS_URL ($SUSFS_BRANCH)"
                return 1
            }
        else
            log "Cloning $SUSFS_URL (branch $SUSFS_BRANCH, depth $DEPTH, no pin)"
            git clone --depth=$DEPTH -q "$SUSFS_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR" || {
                error "susfs clone failed: $SUSFS_URL ($SUSFS_BRANCH)"
                return 1
            }
        fi
    else
        log "$SUSFS_DIR already exists, reusing existing clone"
    fi

    if [ -n "$pin" ]; then
        git -C "$SUSFS_DIR" fetch -q origin "$pin" 2>/dev/null || warning "pin fetch failed for $pin (may already be local)"
        if ! git -C "$SUSFS_DIR" checkout -q "$pin"; then
            error "Failed to checkout pinned commit $pin for KERNEL_VERSION=$KERNEL_VERSION on branch $SUSFS_BRANCH"
            return 1
        fi
        success "Commit pin $pin applied for KERNEL_VERSION=$KERNEL_VERSION (branch $SUSFS_BRANCH)"
    else
        log "No commit pin configured for KERNEL_VERSION=$KERNEL_VERSION, using branch $SUSFS_BRANCH tip"
    fi

    log "susfs4ksu HEAD is now $(git -C "$SUSFS_DIR" rev-parse HEAD)"
}
