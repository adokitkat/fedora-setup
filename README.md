# Fedora 44+ setup checklist

Repositories, drivers, codecs and settings that a default Fedora install does
not have (or does not have enabled), for full codec support, hardware video
decode/encode, the best software encoders, power efficiency and firmware.

Check a machine against this list with:

```sh
bash fedora-setup-check.sh            # offline, read-only, no root
bash fedora-setup-check.sh --online   # also asks LVFS for firmware updates
```

Sources: [RPM Fusion Configuration](https://rpmfusion.org/Configuration),
[RPM Fusion Multimedia](https://rpmfusion.org/Howto/Multimedia),
[Framework: Fedora 44 on the Framework Laptop 13 Pro](https://guides.frame.work/Guide/Fedora+44+Workstation+Installation+on+the+Framework+Laptop+13+Pro/740),
Arch Wiki: [Hardware video acceleration](https://wiki.archlinux.org/title/Hardware_video_acceleration),
[Intel graphics](https://wiki.archlinux.org/title/Intel_graphics),
[Firefox](https://wiki.archlinux.org/title/Firefox#Hardware_video_acceleration),
[Chromium](https://wiki.archlinux.org/title/Chromium#Hardware_video_acceleration).

## 1. Repositories

| What | Why | Command |
|---|---|---|
| Fedora third-party repos | Google Chrome, Steam, the NVIDIA driver repo, and Flathub. Also offered in the first-boot setup and in Discover/GNOME Software. | `sudo fedora-third-party enable` |
| RPM Fusion free + nonfree | Full ffmpeg, x264/x265, full Intel/AMD video drivers, NVIDIA | `sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm` |
| Cisco OpenH264 | Licensed H.264 for Firefox (WebRTC) and GStreamer; usually on by default | `sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1` |
| RPM Fusion AppStream data | RPM Fusion apps show up in Discover/GNOME Software | `sudo dnf install rpmfusion-\*-appstream-data` |
| Full Flathub | Fedora 35–37 limited Flathub to an allowlist. Since Fedora 38 the filter file (`/usr/share/flatpak/fedora-flathub.filter`) has no rules, so all of Flathub is available even though `flatpak remotes` still says `filtered`. Only needed if that file contains `deny` lines (e.g. on an upgraded older install). | `sudo flatpak remote-modify --no-filter --enable flathub` |
| RPM Fusion tainted (optional) | Free tainted: `libdvdcss` for playing DVDs directly. Nonfree tainted: firmware for some older Wi-Fi, Bluetooth and TV-tuner hardware. See [below](#rpm-fusion-tainted). | `sudo dnf install rpmfusion-free-release-tainted rpmfusion-nonfree-release-tainted` |

### RPM Fusion tainted

RPM Fusion has two extra repos, separate from the main free and nonfree ones.
Installing the `*-release-tainted` packages only adds the repo definitions; no
other packages get installed until you ask for them. Most machines need
nothing from either repo.

- **free tainted** (`rpmfusion-free-tainted`): open-source software whose use
  is legally restricted in some countries (for example, laws against breaking
  copy protection).
- **nonfree tainted** (`rpmfusion-nonfree-tainted`): closed-source software
  without clear permission to redistribute from the copyright holder. Some
  countries allow it anyway because it's needed for hardware to work with
  other operating systems. This is mostly firmware.

What they contain for Fedora 44 x86_64 (checked against the mirror in
October 2026):

| Repo | Package | What it's for |
|---|---|---|
| free tainted | `libdvdcss` | Decrypts CSS-protected DVDs so VLC, mpv and other RPM players can play the disc directly. Not needed by MakeMKV (it decrypts on its own) or to play files ripped from a DVD. Flatpak apps can't use the host's copy. |
| free tainted | `ndiswrapper`, `akmod-ndiswrapper` | Loads Windows Wi-Fi drivers on Linux. Legacy; only for old adapters without a Linux driver. |
| nonfree tainted | `b43-firmware` | Older Broadcom Wi-Fi chips that use the `b43` driver |
| nonfree tainted | `broadcom-bt-firmware` | Broadcom Bluetooth chips, including many USB Bluetooth adapters |
| nonfree tainted | `dvb-firmware-nonfree` | Some DVB TV tuner cards and USB sticks |
| nonfree tainted | `nouveau-firmware` | Firmware for the open `nouveau` driver on older NVIDIA GPUs. Not needed with the proprietary NVIDIA driver. |
| nonfree tainted | `p54pci-firmware` | Very old Prism54 PCI Wi-Fi cards |
| nonfree tainted | `akmod-nvidia-open` | Builds NVIDIA's open kernel module from source. RPM Fusion keeps it here on purpose so nobody picks it by mistake. The normal `akmod-nvidia` already uses the open module by default; use this only if you need to patch the kernel module. |

To play DVDs ([RPM Fusion Multimedia](https://rpmfusion.org/Howto/Multimedia)):

```sh
sudo dnf install rpmfusion-free-release-tainted
sudo dnf install libdvdcss
```

For firmware, install only the package for your hardware. RPM Fusion's
catch-all command installs every firmware package in the repo:

```sh
sudo dnf install rpmfusion-nonfree-release-tainted
sudo dnf --repo=rpmfusion-nonfree-tainted install "*-firmware"
```

The package lists change over time. To see the current ones:

```sh
dnf list --available --repo=rpmfusion-free-tainted
dnf list --available --repo=rpmfusion-nonfree-tainted
```

## 2. ffmpeg

Fedora ships `ffmpeg-free`, which leaves out patent-encumbered codecs: no
libx264, libx265, H.264/HEVC hardware encode through ffmpeg, and so on.
RPM Fusion's full `ffmpeg` is a drop-in replacement and is the build RPM Fusion
supports, so it avoids version mismatches with other RPM Fusion packages:

```sh
sudo dnf swap ffmpeg-free ffmpeg --allowerasing
```

With full ffmpeg, `libavcodec-freeworld` (which only complements `ffmpeg-free`)
is not needed.

Check with `ffmpeg -hide_banner -encoders | grep -E 'libx264|libx265|libsvtav1|libfdk_aac|_vaapi|_qsv|_nvenc'`.

## 3. GStreamer codecs

GStreamer apps (GNOME Videos/Showtime, Rhythmbox, Elisa, browsers' fallbacks,
screen recorders, casting tools) need the extra plugin sets:

```sh
sudo dnf install @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
```

This brings `gstreamer1-plugins-bad-freeworld` (x265, more demuxers),
`gstreamer1-plugins-ugly` (x264), `gstreamer1-plugin-libav` (ffmpeg decoders)
and `gstreamer1-plugin-openh264`.

## 4. Hardware video acceleration (VA-API)

Moves video decode and encode onto the GPU's media engine: much less CPU and
battery for video playback, browser video, screen recording, streaming and
casting.

| GPU | Command |
|---|---|
| Intel, Broadwell (2014) and newer, incl. Arc | `sudo dnf install intel-media-driver` (RPM Fusion nonfree). If Fedora's reduced build is installed: `sudo dnf swap libva-intel-media-driver intel-media-driver --allowerasing`. Optional for 32-bit apps (Steam, Wine): `intel-media-driver.i686`. |
| Intel Quick Sync (oneVPL), Tiger Lake and newer | `sudo dnf install intel-vpl-gpu-rt` (ffmpeg `*_qsv`, OBS, HandBrake) |
| Intel, older than Broadwell | `sudo dnf install libva-intel-driver` (not needed on newer GPUs) |
| AMD | `sudo dnf install mesa-va-drivers-freeworld` and `sudo dnf swap mesa-vulkan-drivers{,-freeworld}`. Fedora's own Mesa has H.264/HEVC disabled. For Steam/32-bit apps, add the `.i686` variants. |
| NVIDIA | `sudo dnf install akmod-nvidia`, wait a few minutes for the module to build before rebooting (with Secure Boot, enroll the key). Then `sudo dnf install xorg-x11-drv-nvidia-cuda` (NVENC/NVDEC, CUDA, `nvidia-smi`) and `libva-nvidia-driver` (VA-API decode for browsers). With Steam or other 32-bit apps, also `xorg-x11-drv-nvidia-libs.i686` (required for 32-bit OpenGL/Vulkan) and optionally `libva-nvidia-driver.i686`. |

Verify with `vainfo` (package `libva-utils`): each codec should list
`VAEntrypointVLD` (decode) and, where the GPU supports it, `VAEntrypointEncSlice`
(encode). Don't set `LIBVA_DRIVER_NAME` unless you have to; libva picks the
right driver on its own.

Vendor notes (Arch Wiki):

- **Intel:** Skylake and newer need the GuC/HuC firmware (`linux-firmware`,
  installed by default) for some media features. The newer `xe` kernel driver
  (Lunar Lake / Battlemage and newer) loads both automatically; check with
  `journalctl -k | grep -iE 'guc|huc'`.
- **NVIDIA:** with default settings, `libva-nvidia-driver` can use *more*
  power than CPU decoding, because the GPU boosts its clocks. On driver
  580.105.08 and newer, set `CUDA_DISABLE_PERF_BOOST=1` (for example in
  `/etc/environment`) to avoid that.
- **Vulkan Video** (an alternative to VA-API in ffmpeg, GStreamer, mpv and
  Firefox 153+) is on by default on AMD (RADV, VCN 2+). On Intel (ANV) it is
  still behind `ANV_DEBUG=video-decode,video-encode`. It's experimental in
  browsers, so stick with VA-API there.

## 5. Encoders and decoders

Hardware encoders use a fraction of the CPU and power of software encoders, at
somewhat lower quality per bit. Use them for anything live (streaming, screen
recording, casting, video calls). Use software encoders when file size or
quality matters more than time (archiving, final exports).

The checker lists what ffmpeg and GStreamer can use, and test-encodes a short
clip with each VA-API encoder the GPU reports, so a driver that loads but
fails to encode shows up.

| Codec | Hardware (ffmpeg / GStreamer) | Best software | Notes |
|---|---|---|---|
| H.264 | `h264_vaapi` / `vah264enc`; `h264_qsv` (Intel); `h264_nvenc` (NVIDIA) | `libx264` / `x264enc` | OpenH264 (`libopenh264`, `openh264enc`) is the fallback without RPM Fusion; it's clearly worse per bit. |
| HEVC | `hevc_vaapi` / `vah265enc`; `hevc_qsv`; `hevc_nvenc` | `libx265` / `x265enc` | |
| AV1 | `av1_vaapi` / `vaav1enc`; `av1_qsv`; `av1_nvenc` | `libsvtav1` / `svtav1enc` | HW AV1 encode needs Intel Arc / Meteor Lake+, AMD RDNA3+ or NVIDIA RTX 40+. libaom is the slow reference encoder. |
| AV1 decode | VA-API (`vaav1dec`) where supported | `libdav1d` / `dav1ddec` | dav1d is the fastest software AV1 decoder. |
| AAC | — | `libfdk_aac` / `fdkaacenc` | Clearly better than ffmpeg's native `aac` at 128–192 kbps. |
| Opus | — | `libopus` | Best lossy audio codec where the target supports it. |

## 6. Browsers and Flatpak

- **Firefox (RPM):** uses VA-API for video decode automatically on Intel
  (since 115) and AMD (since 136); check `about:support` → Media. On NVIDIA,
  set `media.hardware-video-decoding.force-enabled` to `true` in
  `about:config`. `mozilla-openh264` (Cisco repo) provides H.264 for WebRTC
  video calls.
- **Zen (Flatpak `app.zen_browser.zen`):** Firefox-based, so the same
  defaults and `about:config` prefs apply; check `about:support` → Media. The
  checker warns if a pref turns acceleration off, and confirms decode is on the
  GPU when Zen's media process has loaded a VA-API driver (needs Zen running;
  the driver loads once a video has played).
- **Chrome / Chromium:** VA-API decode works out of the box since version 143
  on Wayland. Hardware *encode* (WebRTC, screen sharing in Meet) needs
  `--enable-features=AcceleratedVideoEncoder`. Add it to
  `~/.config/chrome-flags.conf` (Chrome) or `~/.config/chromium-flags.conf`
  (Chromium); for the Flatpak, use the same file names under
  `~/.var/app/<app id>/config/`. NVIDIA also needs `VaapiOnNvidiaGPUs`. Check
  `chrome://gpu` → Video Acceleration Information.
- **YouTube** serves AV1 or VP9 by default. If your GPU can't decode those (see
  `vainfo`), the h264ify / enhanced-h264ify extensions force H.264, which
  saves a lot of battery.
- **Flatpak apps** bring their own codecs and drivers as runtime extensions,
  and each runtime pins the exact branch it loads. For example, GNOME 50 and
  KDE 6.11 use `org.freedesktop.Platform.VAAPI.Intel//25.08`, while apps on
  `org.freedesktop.Platform//26.08` need `VAAPI.Intel//26.08`. Having the
  extension in *some* branch isn't enough. `flatpak update` normally installs
  the right ones; the checker reads every installed runtime's and app's
  metadata and reports any branch that's missing:
  - `org.freedesktop.Platform.codecs-extra`: extra codecs.
  - `org.freedesktop.Platform.VAAPI.Intel` on Intel: the Intel VA-API driver.
  - `org.freedesktop.Platform.GL.default`, plus
    `org.freedesktop.Platform.GL.nvidia-<driver version>` on NVIDIA. The
    NVIDIA one must match the host driver version, otherwise Flatpak apps fall
    back to software rendering.
  - **32-bit apps** (Bottles, Steam, Wine, Lutris) also need the 32-bit
    variants they declare: `org.freedesktop.Platform.Compat.i386`, `GL32.*`,
    `codecs_extra.i386`, `VAAPI.Intel.i386` / `VAAPI.nvidia.i386`.

## 7. Power and thermals (laptops)

- **Power profiles:** Fedora 41+ uses `tuned` + `tuned-ppd` instead of
  power-profiles-daemon. Switch profiles from the desktop's battery menu.
  - **Power Saver** turns off CPU turbo. In a software video-encode benchmark
    the same work took about 1.65 cores there versus 1.0 on Balanced.
  - Use Balanced when plugged in or for demanding work. Power Saver is fine
    for light work on battery.
- **Don't install TLP or auto-cpufreq.** They conflict with tuned.
- **Intel CPUs:** `thermald` should be installed and enabled.
- **`powertop`** is good for finding what drains the battery. Don't run
  `--auto-tune` at every boot; it can make USB mice and keyboards lag through
  autosuspend.
- zram swap and the weekly SSD trim (`fstrim.timer`) are on by default; keep
  them.

## 8. Firmware

```sh
fwupdmgr refresh && fwupdmgr get-updates && fwupdmgr update
```

Framework recommends `fwupdmgr` over GUI firmware updaters.

## 9. New hardware

- Fedora ships new kernels quickly. On the newest hardware a driver regression
  is more likely. Fedora keeps the last 3 kernels (`installonly_limit=3`); if
  something breaks after an update, boot the previous kernel from the GRUB
  menu.
- Fingerprint reader: `fprintd`, set up in Settings → Users.

## 10. Useful tools (optional)

| Tool | Package | Use |
|---|---|---|
| `vainfo` | `libva-utils` | Check VA-API drivers and supported codecs |
| `nvtop` | `nvtop` | GPU monitor (Intel, AMD, NVIDIA), including video-engine load |
| `intel_gpu_top` / `gputop` | `intel-gpu-tools` | Intel GPU engine usage. `intel_gpu_top` only works with the older `i915` kernel driver; with `xe` use `gputop` (the `vcs` engine is the video decoder/encoder). |
| `mpv` | `mpv` | `mpv --hwdec=auto -v file` shows whether hardware decode is used |
| `powertop` | `powertop` | Find power drains |
