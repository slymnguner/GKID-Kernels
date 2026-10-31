#!/usr/bin/env bash

WORKDIR="$(pwd)"
RELEASE_DIR="$WORKDIR/artifacts"

KERNEL_NAME="GKID"
USER="slymnguner"
HOST="GKID"
TIMEZONE="Europe/Istanbul"
ANYKERNEL_REPO="https://github.com/slymnguner/AK3-GKID"

KERNEL_DEFCONFIG="gki_defconfig"

KERNEL_VERSION="${KERNEL_VERSION:-6.1}"

sudo timedatectl set-timezone "$TIMEZONE" || export TZ="$TIMEZONE"

RELEASE="$(date +v%y.%m.%d)${RUN_NUM}"

mkdir -p "$RELEASE_DIR" || { echo "FATAL: mkdir $RELEASE_DIR failed" >&2; exit 1; }

GKI_RELEASES_REPO="https://github.com/${GITHUB_REPOSITORY:-slymnguner/GKID-Kernels}"
AK3_ZIP_NAME="$KERNEL_NAME-VARIANT-REL-KVER.zip"
OUTDIR="$WORKDIR/out"
KSRC="$WORKDIR/ksrc"
KERNEL_PATCHES="$WORKDIR/kernel-patches"
PATCHES_DIR="$WORKDIR/patches"

[ -f "$WORKDIR/functions.sh" ] || { echo "FATAL: functions.sh missing at $WORKDIR" >&2; exit 1; }
source "$WORKDIR/functions.sh"

# --- Feature normalization: No_DS overrides NH and DROIDSPACES before
#     any downstream logic (kernel branch selection, patches) runs. ---
if [ "$No_DS" = "true" ]; then
  NH="false"
  DROIDSPACES="false"
fi
# ----------------------------------------------------------------------

KERNEL_REPO="${KERNEL_REPO:-https://github.com/slymnguner/GKI-Duchamp-6.1}"
if [ "$NH" = "true" ]; then
  KERNEL_BRANCH="GKID-NH"
else
  KERNEL_BRANCH="GKID-6.1"
fi

ANDROID_RELEASE="$(android_release_for_version "$KERNEL_VERSION")"
echo "KERNEL_VERSION=$KERNEL_VERSION" >> "${GITHUB_ENV:-/dev/null}"
echo "ANDROID_RELEASE=$ANDROID_RELEASE" >> "${GITHUB_ENV:-/dev/null}"
echo "KERNEL_SOURCE_REPO=$(simplify_gh_url "$KERNEL_REPO")" >> "${GITHUB_ENV:-/dev/null}"
echo "KERNEL_SOURCE_BRANCH=$KERNEL_BRANCH" >> "${GITHUB_ENV:-/dev/null}"

echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")" >> "${GITHUB_ENV:-/dev/null}"
echo "KERNEL_NAME=${KERNEL_NAME}${RUN_NUM}" >> "${GITHUB_ENV:-/dev/null}"
echo "RELEASE_NAME=$KERNEL_NAME $RELEASE" >> "${GITHUB_ENV:-/dev/null}"
echo "RELEASE=$RELEASE" >> "${GITHUB_ENV:-/dev/null}"

BUILD_LOGS="$RELEASE_DIR/build.log"
exec > >(tee -a "$BUILD_LOGS") 2>&1

trap 'echo "SCRIPT EXIT at $(date)" >> "$BUILD_LOGS"' EXIT
trap 'echo "[-] ERROR at line $LINENO: [[$BASH_COMMAND]]" >> "$BUILD_LOGS"' ERR
trap 'echo "[-] Received SIGTERM at $(date) - possible GitHub kill" >> "$BUILD_LOGS"' TERM
trap 'echo "[-] Received SIGINT at $(date)" >> "$BUILD_LOGS"' INT

log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
if kernel_version_eq "$KERNEL_VERSION" "6.1"; then
  git clone -q --depth=1 --recurse-submodules "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC" || { error "kernel clone failed: $KERNEL_REPO ($KERNEL_BRANCH)"; exit 1; }
else
  git clone -q --depth=1 "$KERNEL_REPO" -b "$KERNEL_BRANCH" "$KSRC" || { error "kernel clone failed: $KERNEL_REPO ($KERNEL_BRANCH)"; exit 1; }
fi

cd "$KSRC" || { error "cd $KSRC failed"; exit 1; }
LINUX_VERSION=$(make kernelversion) || { error "make kernelversion failed"; exit 1; }
[ -n "$LINUX_VERSION" ] || { error "empty LINUX_VERSION"; exit 1; }
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG" -print -quit)
[ -n "$DEFCONFIG_FILE" ] || { error "defconfig '$KERNEL_DEFCONFIG' not found under arch/arm64/configs"; exit 1; }
echo "LINUX_VERSION=$LINUX_VERSION" >> "${GITHUB_ENV:-/dev/null}"
cd "$WORKDIR" || { error "cd \$WORKDIR failed"; exit 1; }

log "Setting Kernel variant"
case "$KSU" in
  "KSUN") VARIANT="KernelSU-Next" ;;
  *) VARIANT="Vanilla" ;;
esac

susfs_included && VARIANT+="+SuSFS"
SUSFS_URL="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_DIR="$WORKDIR/susfs"
SUSFS_PATCHES="${SUSFS_DIR}/kernel_patches"

SUSFS_BRANCH="gki-android14-6.1"
SUSFS_PATCH="gki-android14-6.1"

log "Changelog of repos"
clone_susfs 5 || { error "susfs clone for changelog failed"; exit 1; }
cd "$SUSFS_DIR" || { error "cd $SUSFS_DIR failed"; exit 1; }
git log --pretty=format:"- [%h](https://${SUSFS_URL#https://}/commit/%H) %s" -5 "$SUSFS_BRANCH" \
> "$RELEASE_DIR/susfs_changelog-${KERNEL_VERSION}.txt" || { warning "susfs changelog write failed"; }
cd "$WORKDIR" || { error "cd $WORKDIR failed (post-changelog)"; exit 1; }

generate_gh_changelog "slymnguner/GKI-Duchamp-6.1" "$KERNEL_BRANCH" 10 "$RELEASE_DIR/android_kernel-6.1_changelog.txt"
generate_gh_changelog "maxsteeel/nomount" "master" 5 "$RELEASE_DIR/nomount_changelog.txt"
generate_gh_changelog "KernelSU-Next/KernelSU-Next" "dev" 5 "$RELEASE_DIR/KernelSU-Next_changelog.txt"

echo "::group::[*] Downloading Clang"
CLANG_BIN="$WORKDIR/neutron-clang/bin"
mkdir -p "$WORKDIR/neutron-clang" || { error "mkdir neutron-clang failed"; exit 1; }
cd "$WORKDIR/neutron-clang" || { error "cd neutron-clang failed"; exit 1; }
_antman_script=$(curl -fsSL "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") || { error "antman download failed"; exit 1; }
[ -n "$_antman_script" ] || { error "antman script empty"; exit 1; }
bash -s -- -S <<<"$_antman_script" || { error "antman execution failed"; exit 1; }
cd "$WORKDIR" || { error "cd \$WORKDIR failed"; exit 1; }
if [ ! -d "$CLANG_BIN" ]; then
    error "Clang not found in ${CLANG_BIN}."
    exit 1
fi

export PATH="${CLANG_BIN}:$PATH"
echo "::endgroup::"

command -v ccache >/dev/null || { error "ccache not installed"; exit 1; }
export CCACHE_DIR="$HOME/.ccache"
export CCACHE_BASEDIR="$WORKDIR"
export CCACHE_NOHARDLINK=true
export CCACHE_COMPILERCHECK=content
export CC="ccache clang"
export CXX="ccache clang++"

ccache --zero-stats
ccache --max-size=5G
ccache --set-config=sloppiness="pch_defines,time_macros,file_macro,include_file_mtime,include_file_ctime"
ccache --set-config=hash_dir=false
ccache --set-config=base_dir="$WORKDIR"
ccache --set-config=compiler_check=content

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
echo "COMPILER_STRING=$COMPILER_STRING" >> "${GITHUB_ENV:-/dev/null}"

cd "$KSRC" || { error "cd $KSRC failed"; exit 1; }

echo "::group::[+] pahole installation"
build_and_install_pahole || { error "pahole install failed"; exit 1; }
echo "::endgroup::"

echo "::group::[+] Applied patches"


log "Applying BBRv3 patch"
apply_patch_file "$KERNEL_PATCHES/bbrv3/bbrv3.patch" || { error "BBRv3 patch failed"; exit 1; }

log "Applying common patches from $KERNEL_PATCHES/common"
_common_count=0
shopt -s nullglob
for _patch in "$KERNEL_PATCHES"/common/*.patch; do
  apply_patch_file "$_patch" || { error "common patch failed: $_patch"; exit 1; }
  _common_count=$((_common_count + 1))
done
shopt -u nullglob
if [ "$_common_count" -eq 0 ]; then
  warning "no common patches found under $KERNEL_PATCHES/common"
else
  success "Applied $_common_count common patch(es)"
fi



if kernel_version_lt "$KERNEL_VERSION" "6.12"; then
  log "Applying NTSync patches..."
  _ntsync_base=$(curl -fLSs "https://github.com/WildKernels/kernel_patches/raw/main/common/ntsync/ntsync_base.patch") || { error "ntsync_base download failed"; exit 1; }
  [ -n "$_ntsync_base" ] || { error "ntsync_base patch empty"; exit 1; }
  printf '%s' "$_ntsync_base" | apply_patch_file || { error "ntsync_base apply failed"; exit 1; }

  _ntsync_compat=$(curl -fLSs "https://github.com/WildKernels/kernel_patches/raw/main/common/ntsync/ntsync_compat_android14-6.1.patch") || { error "ntsync_compat download failed"; exit 1; }
  [ -n "$_ntsync_compat" ] || { error "ntsync_compat patch empty"; exit 1; }
  printf '%s' "$_ntsync_compat" | apply_patch_file || { error "ntsync_compat apply failed"; exit 1; }
  success "NTSync patches applied"
fi

log "BBG included"
_bbg_script=$(wget -qO- "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh") || { error "BBG setup.sh download failed"; exit 1; }
[ -n "$_bbg_script" ] || { error "BBG setup.sh empty"; exit 1; }
bash <<<"$_bbg_script" || { error "BBG setup.sh execution failed"; exit 1; }
[ -f "security/Kconfig" ] || { error "security/Kconfig missing after BBG"; exit 1; }
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "security/Kconfig" || { error "BBG Kconfig sed failed"; exit 1; }

if [ "$No_DS" = "true" ]; then
  VARIANT+="+NoDS"
fi

if [ "$DROIDSPACES" = "true" ] || [ "$NH" = "true" ]; then
  log "Applying DroidSpaces/NetHunter sysvipc patch"
  apply_patch_file "$KERNEL_PATCHES/droidspaces/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch" || { error "DroidSpaces sysvipc patch failed"; exit 1; }
fi

set -eo pipefail
if [ "$KSU" = "KSUN" ]; then
  if susfs_included; then
    log "KernelSU Next + SuSFS included (pershoot dev-susfs)"
      _knu_script=$(curl -fLSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev-susfs/kernel/setup.sh") \
      || { error "KernelSU-Next setup.sh download failed (pershoot/dev-susfs)"; exit 1; }
      [ -n "$_knu_script" ] || { error "KernelSU-Next setup.sh empty (pershoot/dev-susfs)"; exit 1; }
      bash <<<"$_knu_script" -s dev-susfs || { error "KernelSU-Next setup.sh execution failed (pershoot/dev-susfs)"; exit 1; }

    KSUN_BRANCH="$(git -C "$KSRC/KernelSU-Next" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [ "$KSUN_BRANCH" != "dev-susfs" ]; then
      error "KernelSU Next SuSFS branch mismatch (expected dev-susfs, got ${KSUN_BRANCH:-detached HEAD})"
      exit 1
    fi

    clone_susfs || { error "susfs clone failed (KSU+SUSFS path)"; exit 1; }
    apply_susfs_patches || { error "apply_susfs_patches failed"; exit 1; }
  else
    log "KernelSU Next included (latest tagged release)"
      _knu_dev_script=$(curl -fLSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh") \
      || { error "KernelSU-Next setup.sh download failed (dev)"; exit 1; }
      [ -n "$_knu_dev_script" ] || { error "KernelSU-Next setup.sh empty (dev)"; exit 1; }
      bash <<<"$_knu_dev_script" - || { error "KernelSU-Next setup.sh execution failed (dev)"; exit 1; }
  fi
fi

if [ "$KSU_COMPAT" = "true" ]; then
  VARIANT="Compat+NoLTO+${VARIANT}"
fi

echo "VARIANT=$VARIANT" >> "${GITHUB_ENV:-/dev/null}"

if [ "$NM" = "true" ]; then
  log "Applying NoMount"
  _nomount_script=$(curl -fLSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh") || { error "NoMount download failed"; exit 1; }
  [ -n "$_nomount_script" ] || { error "NoMount setup.sh empty"; exit 1; }
  bash <<<"$_nomount_script" -s master || { error "NoMount setup failed"; exit 1; }
fi
echo "::endgroup::"
set +eo pipefail

AK3_ZIP_NAME=${AK3_ZIP_NAME//KVER/$LINUX_VERSION}
AK3_ZIP_NAME=${AK3_ZIP_NAME//VARIANT/$VARIANT}

log "Applying configs..."
[ -f "$WORKDIR/configs/gki_defconfig.sh" ] || { error "configs/gki_defconfig.sh missing"; exit 1; }
source "$WORKDIR/configs/gki_defconfig.sh" || { error "sourcing gki_defconfig.sh failed"; exit 1; }

if [ "${TODO:-kernel}" = "kernel" ]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null) || { error "git rev-parse failed in $KSRC"; exit 1; }
  SUFFIX="${RUN_NUM}-${LATEST_COMMIT_HASH}"
  config --set-str CONFIG_LOCALVERSION "-${KERNEL_NAME}${SUFFIX}" || { error "config set-str CONFIG_LOCALVERSION failed"; exit 1; }
  config --disable CONFIG_LOCALVERSION_AUTO || { error "config disable CONFIG_LOCALVERSION_AUTO failed"; exit 1; }
  if [ -f scripts/setlocalversion ]; then
    sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion || warning "setlocalversion sed failed (non-fatal)"
  else
    warning "scripts/setlocalversion not found (non-fatal)"
  fi
fi

export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP="$(git -C "$KSRC" log -1 --format=%cd --date=format-local:'%a %b %d %T %z %Y')"
export KCFLAGS="-w"

LINK_CACHE_PATH="/dev/shm/thinlto-cache"
LINKER_SHIM="$WORKDIR/.shims/clang-lto-linker"
MAKE_ARGS=(
  LLVM=1
  LLVM_IAS=1
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  -j$(nproc --all)
  O="$OUTDIR"
)

if [ "${LTO:-}" = "thinLTO" ] && [ "$CLEAN_LTO_CACHE" = "true" ]; then
  rm -rf "$LINK_CACHE_PATH"
  success "ThinLTO cache removed"
fi

if [ "${LTO:-}" = "thinLTO" ]; then
    log "ThinLTO cache enabled"
    mkdir -p "$LINK_CACHE_PATH" || { error "mkdir LINK_CACHE_PATH failed"; exit 1; }
    mkdir -p "$(dirname "$LINKER_SHIM")" || { error "mkdir LINKER_SHIM dir failed"; exit 1; }
    cat > "$LINKER_SHIM" << SHIM || { error "heredoc SHIM write failed"; exit 1; }
#!/usr/bin/env bash
JOBCOUNT=\$(( \$(nproc --all) / 2 ))
exec ld.lld "\$@" --thinlto-cache-dir="$LINK_CACHE_PATH" --thinlto-jobs=\$JOBCOUNT
SHIM
    chmod +x "$LINKER_SHIM" || { error "chmod SHIM failed"; exit 1; }
    MAKE_ARGS+=(LD="$LINKER_SHIM" HOSTLD="$LINKER_SHIM")
fi

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"
KMI_CHECK="$WORKDIR/py/kmi-check-6.x.py"

echo "::group::[*] Generating config"
make ${MAKE_ARGS[@]} "$KERNEL_DEFCONFIG" || { error "make defconfig failed"; exit 1; }
[ -f "$OUTDIR/.config" ] || { error "$OUTDIR/.config not generated"; exit 1; }

if [ "$KSU" = "KSUN" ]; then
  log "Validating KernelSU Next configuration"
  for symbol in CONFIG_KSU CONFIG_KPROBES CONFIG_EXT4_FS; do
    if ! grep -qx "${symbol}=y" "$OUTDIR/.config"; then
      error "KernelSU Next requires ${symbol}=y in the final .config"
      exit 1
    fi
  done
  success "KernelSU Next root prerequisites are enabled"
fi
echo "::endgroup::"

if susfs_included; then

  log "DEBUG: Checking defconfig for SUSFS"
  grep -qi susfs ./arch/arm64/configs/gki_defconfig || { error "SUSFS NOT FOUND in defconfig!"; exit 1; }
  echo ""

  log "DEBUG: Checking .config for SUSFS"
  grep -q CONFIG_KSU_SUSFS "$OUTDIR/.config" || { error "SUSFS NOT ENABLED in .config!"; exit 1; }
  grep -q CONFIG_KSU_SUSFS_SUS_MAP "$OUTDIR/.config" || { error "SUSFS_SUS_MAP not enabled!"; exit 1; }
  echo ""

  if grep -q "CONFIG_KSU_SUSFS" ./arch/arm64/configs/gki_defconfig && ! grep -q "CONFIG_KSU_SUSFS=y" "$OUTDIR/.config"; then
    warning "SUSFS in defconfig but not in .config - checking dependencies..."
    mapfile -t _kconfigs < <(find . -name "Kconfig" -exec grep -l "KSU_SUSFS" {} + 2>/dev/null || true)
    if [ ${#_kconfigs[@]} -eq 0 ]; then
      error "SUSFS requested but no Kconfig with KSU_SUSFS found"
      exit 1
    fi
    grep "depends on" "${_kconfigs[@]}" 2>/dev/null \
      || warning "SUSFS requested but no 'depends on' entries found in Kconfig (may be default=y)"
  fi

fi

if [ "$TEST" = "yes" ]; then
  success "Pipeline test done"
  mkdir -p "$RELEASE_DIR"
  echo "test-${VARIANT}" > "$RELEASE_DIR/test-${VARIANT}.zip"
  exit 0
fi

if [[ "${TODO:-}" == "defconfig" ]]; then
  log "Copying defconfig"
  mkdir -p "$RELEASE_DIR"
  cp "$OUTDIR/.config" "$RELEASE_DIR/config-${VARIANT}.txt"
  exit 0
fi

echo "::group::[*] Aggressive Resource Optimization for FullLTO"

info "Initial storage: $(df -h / | awk 'NR==2 {print $4}') available"
info "Initial memory: $(free -h | awk '/^Mem:/ {print $7}') available"

sudo apt-get clean -qq
sudo apt-get autoremove -y -qq
sudo apt-get autoclean -qq
sudo rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/apt/*

for dir in \
    /usr/share/dotnet \
    /usr/local/lib/android \
    /usr/local/share/powershell \
    /usr/local/share/chromium \
    /usr/local/lib/node_modules \
    /opt/ghc \
    /usr/local/.ghcup \
    /opt/hostedtoolcache \
    /usr/local/share/boost \
    /usr/local/share/gradle-* \
    /usr/local/share/kotlin \
    /usr/local/share/sbt \
    /usr/share/swift \
    /usr/local/share/php \
    /usr/local/share/rust \
    /usr/local/share/go \
    /usr/local/julia* \
    /usr/share/az_* \
    /usr/share/miniconda \
    /opt/microsoft \
    /opt/google \
    /opt/az \
    /usr/lib/jvm \
    /usr/local/lib/heroku \
    /var/lib/containers \
    /var/lib/docker \
    /var/lib/gems \
    /var/lib/mysql \
    /var/lib/postgresql \
    /var/lib/snapd \
    /var/cache/* \
    /tmp/* \
    /home/runner/.cargo \
    /home/runner/.rustup \
    /home/runner/.npm \
    /home/runner/.cache \
    /home/runner/go \
    /home/runner/.local/share \
    /home/runner/.dotnet \
    /home/runner/.gradle \
    /home/runner/.m2 \
    /etc/skel \
    /home/packer \
    /opt/pipx; do
    if [ -e "$dir" ]; then
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")
        sudo rm -rf "$dir" 2>/dev/null || true
        success "Removed $dir ($SIZE)"
    fi
done

sudo docker system prune -af --volumes 2>/dev/null || true
sudo docker builder prune -af 2>/dev/null || true
sudo docker image prune -af 2>/dev/null || true

sudo journalctl --vacuum-size=1M 2>/dev/null || true
sudo find /var/log -type f \( -name "*.log" -o -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true
sudo rm -rf /var/log/journal/* 2>/dev/null || true

if [ -f /swapfile ]; then
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
fi
if [ -f /mnt/swapfile ]; then
    sudo swapoff /mnt/swapfile 2>/dev/null || true
    sudo rm -f /mnt/swapfile
fi

warning "Creating 32GB swap"
if sudo fallocate -l 32G /swapfile 2>/dev/null \
   || sudo dd if=/dev/zero of=/swapfile bs=1M count=32768 status=none 2>/dev/null; then
  sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile \
    || { error "swap enable failed (chmod/mkswap/swapon)"; exit 1; }
  success "32GB swap created and activated"
else
  error "failed to allocate 32GB swapfile (disk full?)"
  exit 1
fi

sudo sysctl -w vm.swappiness=90
sudo sysctl -w vm.vfs_cache_pressure=200
sudo sysctl -w vm.dirty_ratio=5
sudo sysctl -w vm.dirty_background_ratio=2
sudo sysctl -w vm.drop_caches=3
sudo sysctl -w vm.overcommit_memory=1

success "Final storage: $(df -h / | awk 'NR==2 {print $4}') available"
success "Final memory:  $(free -h | awk '/^Mem:/ {print $7}') available | Swap: $(free -h | awk '/^Swap:/ {print $2}')"
echo "::endgroup::"

set -eo pipefail
echo "::group::[*] Building kernel"
make ${MAKE_ARGS[@]} CC="ccache clang" CXX="ccache clang++"
echo "::endgroup::"
set +eo pipefail

cd "$WORKDIR" || { error "cd $WORKDIR failed (pre-anykernel)"; exit 1; }

log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
rm -rf anykernel
git clone -q --depth=1 "$ANYKERNEL_REPO" anykernel || { error "anykernel clone failed"; exit 1; }

AK3_ZIP_NAME=${AK3_ZIP_NAME//REL/$RELEASE}
[ -f "$WORKDIR/anykernel/anykernel.sh" ] || { error "anykernel.sh missing after clone"; exit 1; }
sed -i \
  -e "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${RELEASE} ${LINUX_VERSION} ${VARIANT} by slymnguner/g" \
  -e "s/supported_kernel=\".*\"/supported_kernel=\"${KERNEL_VERSION}\"/g" \
  "$WORKDIR/anykernel/anykernel.sh" || { error "anykernel.sh sed failed"; exit 1; }

cd anykernel || { error "cd anykernel failed"; exit 1; }
log "Zipping anykernel"
if [ ! -f "$KERNEL_IMAGE" ];then
  error "$KERNEL_IMAGE not found."
  exit 1
fi
cp "$KERNEL_IMAGE" . || { error "cp Image to anykernel dir failed"; exit 1; }
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./* || { error "zip failed: $WORKDIR/$AK3_ZIP_NAME"; exit 1; }
[ -f "$WORKDIR/$AK3_ZIP_NAME" ] || { error "zip produced no output: $WORKDIR/$AK3_ZIP_NAME"; exit 1; }
cd "$WORKDIR" || { error "cd back failed"; exit 1; }

echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> "${GITHUB_ENV:-/dev/null}"
mkdir -p "$RELEASE_DIR" || { error "mkdir $RELEASE_DIR failed"; exit 1; }
mv "$WORKDIR/$AK3_ZIP_NAME" "$RELEASE_DIR/" || { error "failed to move $AK3_ZIP_NAME to $RELEASE_DIR"; exit 1; }
