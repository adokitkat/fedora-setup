#!/usr/bin/env bash
# Check a Fedora 44+ machine against README.md.
#
# Read-only: needs no root and changes nothing. Offline by default; pass
# --online to also ask LVFS (fwupd) whether firmware updates are available.
#
# Exit status: 0 when nothing required is missing, 1 otherwise.

set -u

ONLINE=0
for arg in "$@"; do
    case "$arg" in
        --online) ONLINE=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' C=$'\e[36m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'
else
    G= Y= R= C= B= D= N=
fi
n_ok=0 n_miss=0 n_warn=0 n_opt=0

section() { printf '\n%s== %s%s\n' "$B" "$1" "$N"; }
fix()     { [ -n "${1:-}" ] && printf '         %sfix: %s%s\n' "$D" "$1" "$N"; return 0; }
ok()      { n_ok=$((n_ok + 1));     printf '  %s[ OK ]%s %s\n' "$G" "$N" "$1"; }
miss()    { n_miss=$((n_miss + 1)); printf '  %s[MISS]%s %s\n' "$R" "$N" "$1"; fix "${2:-}"; }
warn()    { n_warn=$((n_warn + 1)); printf '  %s[WARN]%s %s\n' "$Y" "$N" "$1"; fix "${2:-}"; }
opt()     { n_opt=$((n_opt + 1));   printf '  %s[ OPT]%s %s\n' "$C" "$N" "$1"; fix "${2:-}"; }
info()    { printf '  [INFO] %s\n' "$1"; }
na()      { printf '  %s[ -- ] %s%s\n' "$D" "$1" "$N"; }

have()      { command -v "$1" >/dev/null 2>&1; }
installed() { rpm -q "$1" >/dev/null 2>&1; }
enabled()   { [ "$(systemctl is-enabled "$1" 2>/dev/null)" = enabled ]; }

if ! have rpm || ! [ -r /etc/fedora-release ]; then
    echo "This script is for Fedora." >&2
    exit 2
fi

# --- system ------------------------------------------------------------------
section "System"
fedora_ver=$(rpm -E %fedora)
info "$(cat /etc/fedora-release), kernel $(uname -r), ${XDG_CURRENT_DESKTOP:-no desktop} ${XDG_SESSION_TYPE:-}"
if [ "$fedora_ver" -ge 44 ] 2>/dev/null; then
    ok "Fedora $fedora_ver"
else
    warn "Fedora $fedora_ver: this list targets Fedora 44+" "sudo dnf system-upgrade (see Fedora docs)"
fi

gpu_intel=0 gpu_amd=0 gpu_nvidia=0
for v in /sys/class/drm/card*/device/vendor; do
    [ -r "$v" ] || continue
    case "$(cat "$v")" in
        0x8086) gpu_intel=1 ;;
        0x1002) gpu_amd=1 ;;
        0x10de) gpu_nvidia=1 ;;
    esac
done
gpus=""
[ $gpu_intel = 1 ] && gpus="$gpus Intel"
[ $gpu_amd = 1 ] && gpus="$gpus AMD"
[ $gpu_nvidia = 1 ] && gpus="$gpus NVIDIA"
info "GPU vendor(s):${gpus:- unknown}"

cpu_intel=0
grep -q GenuineIntel /proc/cpuinfo 2>/dev/null && cpu_intel=1

laptop=0
ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && laptop=1

intel_kmd=""
for d in /sys/class/drm/card*/device/driver; do
    case "$(basename "$(readlink -f "$d")")" in
        xe) intel_kmd=xe ;;
        i915) [ -z "$intel_kmd" ] && intel_kmd=i915 ;;
    esac
done

# --- repositories ------------------------------------------------------------
section "Repositories"
enabled_repos=$(dnf -C -q repolist --enabled 2>/dev/null | awk '{print $1}')
[ -z "$enabled_repos" ] && enabled_repos=$(dnf -q repolist --enabled 2>/dev/null | awk '{print $1}')
repo_on() { printf '%s\n' "$enabled_repos" | grep -qx "$1"; }

if have fedora-third-party; then
    if fedora-third-party query 2>/dev/null | grep -qi "are enabled"; then
        ok "Fedora third-party repositories enabled"
    else
        miss "Fedora third-party repositories disabled" "sudo fedora-third-party enable"
    fi
else
    na "fedora-third-party not installed (non-Workstation/KDE spin?)"
fi

rpmfusion_fix='sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm'
rpmfusion_free=0 rpmfusion_nonfree=0
repo_on rpmfusion-free && rpmfusion_free=1
repo_on rpmfusion-nonfree && rpmfusion_nonfree=1
if [ $rpmfusion_free = 1 ]; then ok "RPM Fusion free enabled"; else miss "RPM Fusion free not enabled" "$rpmfusion_fix"; fi
if [ $rpmfusion_nonfree = 1 ]; then ok "RPM Fusion nonfree enabled"; else miss "RPM Fusion nonfree not enabled" "$rpmfusion_fix"; fi

if repo_on fedora-cisco-openh264; then
    ok "Cisco OpenH264 repo enabled"
else
    miss "Cisco OpenH264 repo not enabled" "sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1"
fi

if [ $rpmfusion_free = 1 ] || [ $rpmfusion_nonfree = 1 ]; then
    if installed rpmfusion-free-appstream-data && installed rpmfusion-nonfree-appstream-data; then
        ok "RPM Fusion AppStream data installed"
    else
        warn "RPM Fusion AppStream data missing (apps won't show in Discover/GNOME Software)" \
            'sudo dnf install rpmfusion-\*-appstream-data'
    fi
fi

if have flatpak; then
    flathub=$(flatpak remotes --columns=name,options,filter 2>/dev/null | awk '$1 == "flathub"')
    # "filtered" only means a filter file is attached. Fedora 38+ ships one
    # with no rules ("# Unfiltered"); only deny rules actually hide apps.
    fh_filter=$(printf '%s' "$flathub" | awk '{print $3}')
    fh_deny=0
    if [ -n "$fh_filter" ] && [ "$fh_filter" != - ]; then
        grep -qsE '^[[:space:]]*deny[[:space:]]' "$fh_filter" && fh_deny=1
    fi
    if [ -z "$flathub" ]; then
        miss "Flathub not configured" "sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
    elif printf '%s' "$flathub" | grep -q disabled; then
        miss "Flathub is disabled" "sudo flatpak remote-modify --no-filter --enable flathub"
    elif [ $fh_deny = 1 ]; then
        warn "Flathub is filtered: $fh_filter has deny rules, so only a subset of apps is visible" \
            "sudo flatpak remote-modify --no-filter flathub"
    else
        ok "Full Flathub enabled"
    fi
else
    na "flatpak not installed"
fi

if installed rpmfusion-free-release-tainted; then
    ok "RPM Fusion free tainted installed"
else
    opt "RPM Fusion free tainted not installed (only for libdvdcss / playing DVDs)" "sudo dnf install rpmfusion-free-release-tainted"
fi
if installed rpmfusion-nonfree-release-tainted; then
    ok "RPM Fusion nonfree tainted installed"
else
    opt "RPM Fusion nonfree tainted not installed (only for some older Wi-Fi/Bluetooth/TV-tuner firmware)" "sudo dnf install rpmfusion-nonfree-release-tainted"
fi

# --- codecs ------------------------------------------------------------------
section "Codecs"
ffmpeg_fix='sudo dnf swap ffmpeg-free ffmpeg --allowerasing'
full_ffmpeg=0
if installed ffmpeg; then
    full_ffmpeg=1
    ok "Full ffmpeg $(rpm -q --qf '%{VERSION}' ffmpeg) (RPM Fusion)"
elif installed ffmpeg-free || installed libavcodec-free; then
    miss "ffmpeg-free installed (no x264/x265/fdk-aac, limited hardware encode)" "$ffmpeg_fix"
else
    miss "ffmpeg not installed" "sudo dnf install ffmpeg"
fi
if [ $full_ffmpeg = 1 ] && installed libavcodec-freeworld; then
    info "libavcodec-freeworld installed: only needed alongside ffmpeg-free; can be removed"
fi

multimedia_fix='sudo dnf install @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin'
for p in gstreamer1-plugins-bad-freeworld gstreamer1-plugins-ugly gstreamer1-plugin-libav gstreamer1-plugin-openh264; do
    if installed "$p"; then ok "$p"; else miss "$p not installed" "$multimedia_fix"; fi
done

if installed libdvdcss; then
    ok "libdvdcss (DVD playback)"
else
    opt "libdvdcss not installed (only to play DVDs directly; not needed by MakeMKV)" "sudo dnf install rpmfusion-free-release-tainted && sudo dnf install libdvdcss"
fi

# --- hardware video acceleration ---------------------------------------------
section "Hardware video acceleration"
if [ $gpu_intel = 1 ]; then
    if installed intel-media-driver; then
        ok "intel-media-driver (iHD, full build from RPM Fusion)"
    elif installed libva-intel-media-driver; then
        warn "libva-intel-media-driver is Fedora's reduced iHD build (some codecs/encoders missing)" \
            "sudo dnf swap libva-intel-media-driver intel-media-driver --allowerasing"
    else
        miss "intel-media-driver not installed (Intel Broadwell+ VA-API)" "sudo dnf install intel-media-driver"
    fi
    if installed intel-vpl-gpu-rt; then
        ok "intel-vpl-gpu-rt (Quick Sync for ffmpeg/OBS/HandBrake)"
    else
        opt "intel-vpl-gpu-rt not installed (Quick Sync for ffmpeg/OBS/HandBrake)" "sudo dnf install intel-vpl-gpu-rt"
    fi
    if installed libva-intel-driver; then
        info "libva-intel-driver (i965) installed: only needed for pre-Broadwell Intel GPUs; harmless otherwise"
    fi
    if [ -n "$intel_kmd" ]; then
        huc=$(journalctl -k -b --no-pager -q 2>/dev/null | grep -iE 'HuC (firmware|authenticated)|Using HuC' | tail -n 1)
        if [ -n "$huc" ]; then
            ok "Intel HuC media firmware loaded ($intel_kmd driver)"
        else
            info "Intel GPU on the $intel_kmd driver; HuC status unknown (needs journal access: journalctl -k | grep -i huc)"
        fi
    fi
fi
if [ $gpu_amd = 1 ]; then
    if installed mesa-va-drivers-freeworld; then
        ok "mesa-va-drivers-freeworld (AMD H.264/HEVC VA-API)"
    else
        miss "mesa-va-drivers-freeworld not installed (Fedora's Mesa has H.264/HEVC disabled)" "sudo dnf install mesa-va-drivers-freeworld"
    fi
    if installed mesa-vulkan-drivers-freeworld; then
        ok "mesa-vulkan-drivers-freeworld (Vulkan video)"
    else
        warn "mesa-vulkan-drivers-freeworld not installed (Vulkan video)" "sudo dnf swap mesa-vulkan-drivers{,-freeworld}"
    fi
fi
if [ $gpu_nvidia = 1 ]; then
    if grep -q '^nvidia ' /proc/modules 2>/dev/null; then
        ok "NVIDIA proprietary driver loaded"
    elif rpm -qa 'akmod-nvidia*' 'kmod-nvidia*' 2>/dev/null | grep -q .; then
        warn "NVIDIA driver installed but not loaded (module still building, Secure Boot key not enrolled, or reboot pending)" \
            "sudo akmods --force && reboot; with Secure Boot: sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
    else
        miss "NVIDIA proprietary driver not installed (running nouveau)" "sudo dnf install akmod-nvidia"
    fi
    if installed xorg-x11-drv-nvidia-cuda; then
        ok "xorg-x11-drv-nvidia-cuda (NVENC/NVDEC, CUDA, nvidia-smi)"
    else
        warn "xorg-x11-drv-nvidia-cuda not installed (NVENC/NVDEC for ffmpeg, OBS)" "sudo dnf install xorg-x11-drv-nvidia-cuda"
    fi
    if installed libva-nvidia-driver; then
        ok "libva-nvidia-driver (VA-API on NVDEC)"
        if grep -qs '^ *CUDA_DISABLE_PERF_BOOST=1' /etc/environment ~/.config/environment.d/*.conf 2>/dev/null \
            || [ "${CUDA_DISABLE_PERF_BOOST:-}" = 1 ]; then
            ok "CUDA_DISABLE_PERF_BOOST=1 (VA-API decode without clock boost)"
        else
            warn "CUDA_DISABLE_PERF_BOOST not set: NVDEC via VA-API can use more power than CPU decode (driver 580.105+)" \
                "echo CUDA_DISABLE_PERF_BOOST=1 | sudo tee -a /etc/environment"
        fi
    else
        warn "libva-nvidia-driver not installed (VA-API decode in browsers etc.)" "sudo dnf install libva-nvidia-driver"
    fi
fi

# 32-bit (i686) libraries come in with Steam, Wine and other 32-bit apps. They
# need 32-bit drivers too, otherwise those apps lose GPU or video acceleration.
has_i686() { rpm -q "$1.i686" >/dev/null 2>&1; }
if has_i686 mesa-dri-drivers || has_i686 mesa-libGL || installed steam; then
    info "32-bit (i686) graphics stack installed (Steam, Wine, ...): checking 32-bit drivers"
    if [ $gpu_intel = 1 ]; then
        if has_i686 intel-media-driver; then
            ok "intel-media-driver.i686 (VA-API for 32-bit apps)"
        elif has_i686 libva-intel-media-driver; then
            warn "libva-intel-media-driver.i686 is Fedora's reduced iHD build" \
                "sudo dnf swap libva-intel-media-driver.i686 intel-media-driver.i686 --allowerasing"
        else
            opt "intel-media-driver.i686 not installed (VA-API video in 32-bit apps)" "sudo dnf install intel-media-driver.i686"
        fi
    fi
    if [ $gpu_amd = 1 ]; then
        if has_i686 mesa-va-drivers-freeworld; then
            ok "mesa-va-drivers-freeworld.i686 (H.264/HEVC VA-API for 32-bit apps)"
        else
            warn "mesa-va-drivers-freeworld.i686 not installed (H.264/HEVC VA-API in 32-bit apps)" \
                "sudo dnf install mesa-va-drivers-freeworld.i686"
        fi
        if has_i686 mesa-vulkan-drivers-freeworld; then
            ok "mesa-vulkan-drivers-freeworld.i686 (32-bit Vulkan video)"
        elif has_i686 mesa-vulkan-drivers; then
            warn "32-bit Vulkan driver is Fedora's build (no H.264/HEVC Vulkan video)" \
                "sudo dnf swap mesa-vulkan-drivers.i686 mesa-vulkan-drivers-freeworld.i686"
        fi
    fi
    if [ $gpu_nvidia = 1 ] && rpm -qa 'akmod-nvidia*' 'kmod-nvidia*' 2>/dev/null | grep -q .; then
        if has_i686 xorg-x11-drv-nvidia-libs; then
            ok "xorg-x11-drv-nvidia-libs.i686 (32-bit OpenGL/Vulkan on NVIDIA)"
        else
            miss "xorg-x11-drv-nvidia-libs.i686 not installed (32-bit games/Wine can't use the NVIDIA GPU)" \
                "sudo dnf install xorg-x11-drv-nvidia-libs.i686"
        fi
        if has_i686 libva-nvidia-driver; then
            ok "libva-nvidia-driver.i686 (VA-API for 32-bit apps)"
        else
            opt "libva-nvidia-driver.i686 not installed (VA-API video in 32-bit apps)" "sudo dnf install libva-nvidia-driver.i686"
        fi
    fi
fi

have_ffenc() {  # name: is it in ffmpeg's encoder list
    [ -n "${ff_enc:-}" ] || ff_enc=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    printf '%s\n' "$ff_enc" | grep -qE "^ [A-Z.]{6} $1 "
}
ff_try() {  # label, then ffmpeg args placed before the output; encodes 0.5 s of test video
    label=$1; shift
    if timeout 30 ffmpeg -hide_banner -loglevel error -nostdin "$@" -f null - </dev/null >/dev/null 2>&1; then
        ok "$label test encode works"
    else
        warn "$label test encode failed" "run the ffmpeg command by hand to see the error"
    fi
}
ff_src=(-f lavfi -i testsrc2=size=1280x720:rate=30 -t 0.5)

if have vainfo; then
    found_render=0
    for dev in /dev/dri/renderD*; do
        [ -e "$dev" ] || continue
        found_render=1
        out=$(timeout 10 vainfo --display drm --device "$dev" 2>&1)
        driver=$(printf '%s\n' "$out" | sed -n 's/.*Driver version: *//p' | head -n 1)
        if [ -z "$driver" ]; then
            warn "$dev: VA-API driver failed to load" "see 'vainfo --display drm --device $dev'"
            continue
        fi
        info "$dev: $driver"
        if printf '%s\n' "$out" | grep -q 'VAProfileH264.*VAEntrypointVLD'; then
            ok "$dev: H.264 hardware decode"
        else
            warn "$dev: no H.264 hardware decode (needs the freeworld/nonfree driver above, or the GPU lacks it)"
        fi
        dec_list="" enc_list=""
        for codec in H264:H.264 HEVC:HEVC VP9:VP9 AV1:AV1 VVC:VVC; do
            prof=${codec%%:*} name=${codec#*:}
            printf '%s\n' "$out" | grep -q "VAProfile${prof}.*VAEntrypointVLD" && dec_list="$dec_list $name"
            printf '%s\n' "$out" | grep -q "VAProfile${prof}.*VAEntrypointEncSlice" && enc_list="$enc_list $name"
        done
        info "$dev: hardware decode:${dec_list:- none}"
        info "$dev: hardware encode:${enc_list:- none}"
        case " $enc_list " in
            *" H.264 "*) ;;
            *) warn "$dev: no H.264 hardware encode (needs the freeworld/nonfree driver above, or the GPU lacks it)" ;;
        esac
        if have ffmpeg; then
            for pair in H.264:h264_vaapi HEVC:hevc_vaapi AV1:av1_vaapi; do
                name=${pair%%:*} enc=${pair#*:}
                case " $enc_list " in *" $name "*) ;; *) continue ;; esac
                if have_ffenc "$enc"; then
                    ff_try "$dev: ffmpeg $enc" -vaapi_device "$dev" "${ff_src[@]}" -vf format=nv12,hwupload -c:v "$enc"
                else
                    warn "$dev: ffmpeg lacks $enc" "$ffmpeg_fix"
                fi
            done
        fi
    done
    [ $found_render = 0 ] && warn "no /dev/dri/renderD* device found"
else
    opt "vainfo not installed, can't verify VA-API" "sudo dnf install libva-utils"
fi

if have ffmpeg; then
    if [ $gpu_intel = 1 ] && installed intel-vpl-gpu-rt && have_ffenc h264_qsv; then
        ff_try "ffmpeg h264_qsv (Quick Sync)" "${ff_src[@]}" -pix_fmt nv12 -c:v h264_qsv
    fi
    if [ $gpu_nvidia = 1 ] && grep -q '^nvidia ' /proc/modules 2>/dev/null && have_ffenc h264_nvenc; then
        ff_try "ffmpeg h264_nvenc" "${ff_src[@]}" -c:v h264_nvenc
    fi
fi

# --- encoders and decoders ---------------------------------------------------
section "Software encoders and decoders"
if have ffmpeg; then
    ffenc_check() {  # level encoder description
        if have_ffenc "$2"; then
            ok "ffmpeg $2 ($3)"
        else
            "$1" "ffmpeg lacks $2 ($3)" "$ffmpeg_fix"
        fi
    }
    ffenc_check miss libx264 "best software H.264"
    ffenc_check warn libx265 "best software HEVC"
    ffenc_check warn libsvtav1 "fast software AV1"
    ffenc_check warn libopus "Opus audio"
    ffenc_check opt libfdk_aac "best AAC; better than native aac at 128-192 kbps"
    if ffmpeg -hide_banner -decoders 2>/dev/null | grep -qE '^ [A-Z.]{6} libdav1d '; then
        ok "ffmpeg libdav1d (fastest software AV1 decoder)"
    else
        warn "ffmpeg lacks libdav1d" "$ffmpeg_fix"
    fi
fi

if have gst-inspect-1.0; then
    gst_check() {  # level element description fix
        if gst-inspect-1.0 --exists "$2" 2>/dev/null; then
            ok "GStreamer $2 ($3)"
        else
            "$1" "GStreamer $2 missing ($3)" "$4"
        fi
    }
    gst_check miss x264enc "H.264 software encoder" "$multimedia_fix"
    gst_check warn x265enc "HEVC software encoder" "sudo dnf install gstreamer1-plugins-bad-freeworld"
    gst_check opt svtav1enc "AV1 software encoder" "sudo dnf install gstreamer1-plugins-bad-free"
    gst_check warn avdec_h264 "ffmpeg-based decoders" "sudo dnf install gstreamer1-plugin-libav"
    gst_check warn dav1ddec "AV1 software decoder" "sudo dnf install gstreamer1-plugin-dav1d"
    gst_check opt fdkaacenc "AAC encoder" "sudo dnf install gstreamer1-plugins-bad-free"
    gst_check opt openh264enc "fallback H.264 without RPM Fusion" "sudo dnf install gstreamer1-plugin-openh264"
    if [ $gpu_intel = 1 ] || [ $gpu_amd = 1 ]; then
        gst_check warn vah264dec "VA-API H.264 decode" "sudo dnf install gstreamer1-plugins-bad-free (and the VA driver above)"
        gst_check warn vah264enc "VA-API H.264 encode" "sudo dnf install gstreamer1-plugins-bad-free (and the VA driver above)"
    fi
    [ $gpu_intel = 1 ] && gst_check opt qsvh264enc "Quick Sync H.264 encode" "sudo dnf install intel-vpl-gpu-rt"
    [ $gpu_nvidia = 1 ] && gst_check warn nvh264enc "NVENC H.264 encode" "sudo dnf install xorg-x11-drv-nvidia-cuda gstreamer1-plugins-bad-freeworld"
else
    na "GStreamer tools not installed (gst-inspect-1.0, package gstreamer1)"
fi

# --- browsers and flatpak ----------------------------------------------------
section "Browsers and Flatpak"
if installed firefox; then
    if installed mozilla-openh264; then
        ok "Firefox: mozilla-openh264 (H.264 for WebRTC calls)"
    else
        warn "Firefox: mozilla-openh264 missing (H.264 WebRTC calls)" "sudo dnf install mozilla-openh264"
    fi
    if [ $gpu_nvidia = 1 ] && [ $gpu_intel = 0 ] && [ $gpu_amd = 0 ]; then
        info "Firefox on NVIDIA: set media.hardware-video-decoding.force-enabled=true in about:config"
    else
        info "Firefox: VA-API decode is on by default for Intel/AMD (check about:support > Media)"
    fi
fi

if { have flatpak && flatpak info app.zen_browser.zen >/dev/null 2>&1; } || have zen; then
    # Zen uses Firefox's prefs; flag any that turn hardware acceleration off.
    zen_off=$(grep -shoE 'user_pref\("(media\.hardware-video-decoding\.enabled|media\.ffmpeg\.vaapi\.enabled)", *false\)|user_pref\("(gfx\.webrender\.software|layers\.acceleration\.disabled)", *true\)' \
        "$HOME"/.var/app/app.zen_browser.zen/.zen/*/{prefs,user}.js "$HOME"/.zen/*/{prefs,user}.js | sort -u)
    if [ -n "$zen_off" ]; then
        warn "Zen: hardware acceleration turned off in about:config: $(printf '%s' "$zen_off" | tr '\n' ' ')" "reset those prefs in about:config"
    else
        ok "Zen: no prefs turn off hardware acceleration"
    fi
    # The RDD process is the media decoder; if it loaded a VA-API driver, decode is on the GPU.
    zen_drv=""
    for pid in $(pgrep -x 'RDD Process'); do
        case "$(readlink "/proc/$pid/exe")" in */zen|*/zen-bin) ;; *) continue ;; esac
        zen_drv=$(grep -oE '[^/]+_drv_video\.so' "/proc/$pid/maps" 2>/dev/null | sort -u | paste -sd ' ')
    done
    if [ -n "$zen_drv" ]; then
        ok "Zen: video decode uses VA-API ($zen_drv)"
    elif [ $gpu_nvidia = 1 ] && [ $gpu_intel = 0 ] && [ $gpu_amd = 0 ]; then
        info "Zen on NVIDIA: set media.hardware-video-decoding.force-enabled=true in about:config"
    else
        info "Zen: VA-API decode not confirmed (play a video with Zen open and rerun, or check about:support > Media)"
    fi
fi

chrome_flags_hint() {  # display name, flags file
    if grep -qs 'AcceleratedVideoEncoder' "$2"; then
        ok "$1: hardware video encode enabled ($2)"
    else
        opt "$1: hardware video encode (WebRTC, screen sharing) is off by default" \
            "echo --enable-features=AcceleratedVideoEncoder >> $2"
    fi
}
installed google-chrome-stable && chrome_flags_hint "Chrome" "$HOME/.config/chrome-flags.conf"
installed chromium && chrome_flags_hint "Chromium" "$HOME/.config/chromium-flags.conf"

if have flatpak; then
    fp_apps=$(flatpak list --app --columns=application 2>/dev/null)
    printf '%s\n' "$fp_apps" | grep -qx com.google.Chrome \
        && chrome_flags_hint "Chrome (Flatpak)" "$HOME/.var/app/com.google.Chrome/config/chrome-flags.conf"
    printf '%s\n' "$fp_apps" | grep -qx org.chromium.Chromium \
        && chrome_flags_hint "Chromium (Flatpak)" "$HOME/.var/app/org.chromium.Chromium/config/chromium-flags.conf"

    if [ -n "$fp_apps" ]; then
        # Every runtime pins the extension branches it loads (GNOME 50 and
        # KDE 6.11 both use VAAPI.Intel//25.08, freedesktop 26.08 uses 26.08),
        # and 32-bit apps (Bottles, Steam, Wine) declare their own .i386
        # extensions. Read those extension points and check that the exact
        # branch each one asks for is installed.
        declare -A fp_have=() fp_need=() fp_users=() fp_rt_users=()
        while read -r name branch; do
            [ -n "$name" ] && fp_have["$name/$branch"]=1
        done < <(flatpak list --runtime --columns=application,branch 2>/dev/null)

        nv_ver=""
        if [ $gpu_nvidia = 1 ] && [ -r /sys/module/nvidia/version ]; then
            nv_ver=$(tr . - < /sys/module/nvidia/version)
        fi

        fp_points() {  # flatpak info args -> "name version versions" per extension point
            flatpak info --show-metadata "$@" 2>/dev/null | awk '
                function out() { if (n != "") print n, (v == "" ? "-" : v), (vs == "" ? "-" : vs) }
                /^\[/ { out(); n = v = vs = ""
                        if ($1 == "[Extension") { n = $2; sub(/\]$/, "", n) }
                        next }
                n != "" { line = $0; gsub(/[ \t]/, "", line)
                          k = line; sub(/=.*/, "", k); val = line; sub(/^[^=]*=/, "", val)
                          if (k == "version") v = val; else if (k == "versions") vs = val }
                END { out() }'
        }
        fp_add() {  # extension name, candidate branches (;-separated), users...
            local key="$1|$2" u
            shift 2
            fp_need["$key"]=1
            for u in "$@"; do
                case " ${fp_users[$key]:-} " in
                    *" $u "*) ;;
                    *) fp_users["$key"]="${fp_users[$key]:-} $u" ;;
                esac
            done
        }
        fp_collect() {  # owner branch, users (space-separated), flatpak info args...
            local owner=$1 users=$2 name ver vers cands
            shift 2
            while read -r name ver vers; do
                if [ "$vers" != - ]; then cands=$vers
                elif [ "$ver" != - ]; then cands=$ver
                else cands=$owner; fi
                # shellcheck disable=SC2086  # users is a word list
                case "$name" in
                    org.freedesktop.Platform.codecs-extra|org.freedesktop.Platform.codecs_extra.i386|org.freedesktop.Platform.Compat.i386)
                        fp_add "$name" "$cands" $users ;;
                    org.freedesktop.Platform.VAAPI.Intel|org.freedesktop.Platform.VAAPI.Intel.i386)
                        [ $gpu_intel = 1 ] && fp_add "$name" "$cands" $users ;;
                    org.freedesktop.Platform.VAAPI.nvidia|org.freedesktop.Platform.VAAPI.nvidia.i386)
                        [ -n "$nv_ver" ] && fp_add "$name" "$cands" $users ;;
                    org.freedesktop.Platform.GL|org.freedesktop.Platform.GL32)
                        fp_add "$name.default" "$cands" $users
                        [ -n "$nv_ver" ] && fp_add "$name.nvidia-$nv_ver" "1.4" $users ;;
                esac
            done < <(fp_points "$@")
        }

        while read -r app branch runtime; do
            [ -n "$app" ] || continue
            fp_collect "$branch" "$app" "$app" "$branch"   # the app's own (32-bit) extension points
            fp_rt_users["$runtime"]="${fp_rt_users[$runtime]:-} $app"
        done < <(flatpak list --app --columns=application,branch,runtime 2>/dev/null)
        for rt in "${!fp_rt_users[@]}"; do
            fp_collect "${rt##*/}" "${fp_rt_users[$rt]}" "$rt"
        done

        while read -r key; do
            [ -n "$key" ] || continue
            name=${key%%|*} cands=${key#*|} found=""
            IFS=';' read -ra cand_list <<< "$cands"
            for c in "${cand_list[@]}"; do
                if [ -n "${fp_have[$name/$c]:-}" ]; then found=$c; break; fi
            done
            users=${fp_users[$key]# }
            n_users=$(wc -w <<< "$users")
            if [ -n "$found" ]; then
                ok "Flatpak $name//$found ($n_users app(s))"
            else
                warn "Flatpak $name//${cand_list[0]} missing, needed by: $users" \
                    "flatpak install flathub $name//${cand_list[0]}"
            fi
        done < <(printf '%s\n' "${!fp_need[@]}" | sort)
    fi
fi

# --- power -------------------------------------------------------------------
section "Power and thermals"
if installed tuned && installed tuned-ppd; then
    if systemctl is-active -q tuned 2>/dev/null; then
        ok "tuned + tuned-ppd active"
    else
        warn "tuned installed but not running" "sudo systemctl enable --now tuned"
    fi
elif installed power-profiles-daemon; then
    info "power-profiles-daemon in use (Fedora 41+ defaults to tuned-ppd; either works)"
else
    warn "no power-profile daemon" "sudo dnf install tuned tuned-ppd && sudo systemctl enable --now tuned"
fi

for conflicting in tlp auto-cpufreq; do
    if installed "$conflicting" || have "$conflicting"; then
        warn "$conflicting installed: conflicts with tuned/power profiles" "sudo dnf remove $conflicting"
    fi
done

if have tuned-adm; then
    info "tuned profile: $(tuned-adm active 2>/dev/null | sed 's/^Current active profile: //')"
fi
[ -r /sys/firmware/acpi/platform_profile ] && info "platform profile: $(cat /sys/firmware/acpi/platform_profile)"
if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    if [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ]; then
        info "CPU turbo is OFF (Power Saver): fine on battery, slow for heavy work"
    else
        info "CPU turbo is on"
    fi
fi
if [ $laptop = 1 ]; then
    for ac in /sys/class/power_supply/A*/online; do
        [ -r "$ac" ] || continue
        if [ "$(cat "$ac")" = 1 ]; then info "on AC power"; else info "on battery"; fi
        break
    done
fi

if [ $cpu_intel = 1 ]; then
    if installed thermald && enabled thermald; then
        ok "thermald installed and enabled (Intel)"
    else
        warn "thermald not installed/enabled (Intel thermal management)" "sudo dnf install thermald && sudo systemctl enable --now thermald"
    fi
fi

if enabled powertop.service; then
    warn "powertop.service (auto-tune at boot) enabled: can make USB input devices lag" "sudo systemctl disable powertop.service"
fi

if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then
    ok "zram swap active"
else
    warn "zram swap not active" "sudo dnf install zram-generator-defaults && reboot"
fi

if enabled fstrim.timer; then
    ok "fstrim.timer enabled (weekly SSD trim)"
else
    warn "fstrim.timer disabled" "sudo systemctl enable --now fstrim.timer"
fi

# --- firmware ----------------------------------------------------------------
section "Firmware"
if have fwupdmgr; then
    ok "fwupd installed"
    if [ $ONLINE = 1 ]; then
        timeout 120 fwupdmgr refresh --force >/dev/null 2>&1 </dev/null
        fw_out=$(timeout 120 fwupdmgr get-updates --no-unreported-check 2>&1 </dev/null)
        fw_rc=$?
        case $fw_rc in
            0) warn "firmware updates available" "fwupdmgr update"
               printf '%s\n' "$fw_out" | grep -E '│|New version|^[A-Za-z].*:$' | head -n 20 | sed 's/^/         /' ;;
            2) ok "firmware is up to date (LVFS)" ;;
            *) info "could not check firmware updates (exit $fw_rc)" ;;
        esac
    else
        info "run with --online (or 'fwupdmgr get-updates') to check for firmware updates"
    fi
else
    miss "fwupd not installed" "sudo dnf install fwupd"
fi

# --- kernels -----------------------------------------------------------------
section "Kernels"
n_kernels=$(rpm -q kernel-core 2>/dev/null | wc -l)
limit=$(dnf --dump-main-config 2>/dev/null | sed -n 's/^installonly_limit *= *//p' | head -n 1)
info "$n_kernels kernel(s) installed, installonly_limit=${limit:-3 (default)}"
if [ "${limit:-3}" -lt 2 ] 2>/dev/null; then
    warn "installonly_limit below 2: no older kernel to fall back to" "sudo dnf config-manager setopt installonly_limit=3"
elif [ "$n_kernels" -ge 2 ]; then
    ok "an older kernel is available as a fallback in GRUB"
else
    info "only one kernel installed; a fallback appears after the next kernel update"
fi

# --- fingerprint -------------------------------------------------------------
section "Fingerprint"
if have fprintd-list; then
    fp=$(timeout 5 fprintd-list "$USER" 2>&1)
    if printf '%s' "$fp" | grep -qi "no devices"; then
        na "no fingerprint reader"
    elif printf '%s' "$fp" | grep -qi "no fingers enrolled"; then
        opt "fingerprint reader found, no fingers enrolled" "Settings > Users > Fingerprint Login (or: fprintd-enroll)"
    elif printf '%s' "$fp" | grep -qi "fingerprints for user"; then
        ok "fingerprint enrolled"
    else
        info "fingerprint status unknown"
    fi
else
    na "fprintd not installed"
fi

# --- tools -------------------------------------------------------------------
section "Useful tools (optional)"
check_tool() {  # command package description
    if have "$1"; then ok "$1 ($3)"; else opt "$1 not installed ($3)" "sudo dnf install $2"; fi
}
check_tool vainfo libva-utils "VA-API check"
check_tool nvtop nvtop "GPU monitor"
check_tool powertop powertop "power drains"
check_tool mpv mpv "'mpv --hwdec=auto -v' shows whether HW decode works"
if [ $gpu_intel = 1 ]; then
    if [ "$intel_kmd" = xe ]; then
        check_tool gputop intel-gpu-tools "Intel GPU engines; intel_gpu_top doesn't support the xe driver"
    else
        check_tool intel_gpu_top intel-gpu-tools "Intel GPU engines"
    fi
fi

# --- summary -----------------------------------------------------------------
printf '\n%sSummary:%s %s%d ok%s, %s%d missing%s, %s%d warnings%s, %s%d optional%s\n' \
    "$B" "$N" "$G" "$n_ok" "$N" "$R" "$n_miss" "$N" "$Y" "$n_warn" "$N" "$C" "$n_opt" "$N"
[ $n_miss -eq 0 ]
