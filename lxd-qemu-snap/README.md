# External QEMU snap for LXD snap

The idea behind this feature is to allow LXD users to build their own snap
containing QEMU and then plug it into the LXD snap, so that LXD uses this
custom QEMU instead of the built-in one.

To make it easier to test this feature and simplify the user experience,
we provide a reference snapcraft.yaml file. It is intended solely as
a starting point for building and customizing your own QEMU snap.

Please note that we do not provide regular or security updates for this
reference example, as it is meant for documentation and educational purposes only.

## How to build and use (example)

```sh
cd lxd-qemu-snap

# clean up previous builds
rm -f qemu-for-lxd_*.snap

# build
snapcraft pack

# install
sudo snap install qemu-for-lxd_*.snap --devmode

# connect snaps
sudo snap connect lxd:gpu-2604 mesa-2604:gpu-2604
sudo snap connect lxd:qemu-external qemu-for-lxd:qemu-external
```

## AMD ROCm native-context experiment

Build the patched guest kernel and the virtio-enabled ROCr runtime in the
`amd` Workshop:

```sh
./build-amd.sh kernel
./build-amd.sh rocr
```

Build and connect the experimental QEMU snap:

```sh
./build-amd.sh install-snap
```

QEMU runs as the `lxd` user, which cannot open the host's `/dev/kfd` or
render node by default. Grant it access (this is lost on reboot):

```sh
sudo setfacl -m u:lxd:rw /dev/kfd /dev/dri/renderD128
```

Without this, QEMU logs `virgl could not be initialized` and the guest hangs
on its first GPU command.

Create the VM, then install and test PyTorch:

```sh
./build-amd.sh vm
./build-amd.sh pytorch
./build-amd.sh test
```

To restore LXD's bundled QEMU:

```sh
./build-amd.sh uninstall-snap
```

The `vm` command creates `amd-rocm` if needed, adds a `virtio-vga-rutabaga` GPU
with `hostmem` and `rocm` enabled, installs the already-built kernel packages,
reboots it, and verifies the running guest kernel. QEMU does not pass a render
node to rutabaga, so virglrenderer picks the GPU itself.

The VM uses Ubuntu 26.04 userspace with a 7.0 kernel built from Ubuntu's
pinned `Ubuntu-7.0.0-44.44` source tag as a separate `rocm-virtio` flavour
(`uname -r` reports `7.0.0-44-rocm-virtio`), using the same amd64 annotations as
the generic flavour. It is installed alongside the stock kernel and set as the
GRUB default.
This experiment uses QEMU 11.1.50 because
the ROCm RFC does not apply to LXD 6.10.1's bundled QEMU 10.2.1. QEMU is
built with rutabaga 1.90, patched with `patches/rutabaga-rocm.patch` to match
the virglrenderer fork's ROCm flag and to fix the C `rutabaga_fence.ring_idx`
type, which otherwise makes ring fences hang. `patches/qemu-rutabaga-capsets.patch`
adds `virgl2` (OpenGL), `drm` (amdgpu native context) and `rocm` properties to
QEMU's rutabaga device. The
`install-snap` command connects this external QEMU to LXD; LXD 6.10.1 itself
only requires QEMU 8.2.2 or newer.

The `pytorch` command installs AMD's stock ROCm 7.14.0 PyTorch wheels for
`gfx1150` and replaces only their ROCr library
with one built from `patches/rocr-runtime-virtio.patch`, taken from AMD's
`rocmvirtio/rocm-virtio` image. ROCr is
built with Ubuntu's LLVM 22, which is needed for the gfx1250 shaders it embeds.
`test` checks a matrix multiplication against the CPU. With `--images DIR` it
also times image generation with `stabilityai/sd-turbo` and saves the images in
`DIR` inside the VM.

## How to use with virgl (only specific to this example of snapcraft.yaml)

As part of this external QEMU snap example, we build QEMU with virglrenderer
library support. Of course, this is not required, and in your specific use
case you may choose to omit it. The following instructions show how to verify
that the external QEMU snap with virgl support is working correctly.

```sh
lxc init images:ubuntu/noble/desktop desktop -c limits.memory=8GiB --vm

# modify instance configuration:
lxc config edit desktop

# choose an appropriate renderer:
ls -la /dev/dri/by-path/*-render

# for example, on my system it is /dev/dri/by-path/pci-0000:67:00.0-render
# lspci | grep -E "(3D|VGA)" shows:
# 67:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Rembrandt (rev d8)

# add the following lines:
  raw.apparmor: |-
    /snap/lxd/*/gpu-2604/** mr,
    /dev/dri/ r,
    /dev/dri/card[0-9]* rw,
    /dev/dri/renderD[0-9]* rw,
    /run/udev/data/c226:[0-9]* r,  # 226 drm
    /sys/devices/** r,
    /sys/bus/** r,
  raw.qemu: -display egl-headless,rendernode=/dev/dri/by-path/pci-0000:67:00.0-render
  raw.qemu.conf: |-
    [device "qemu_gpu"]
    driver = "virtio-vga-gl"

# try it
lxc start desktop --console=vga

# you can check output from:
dmesg | grep -i drm
# if you see:
# [drm] features: +virgl ...
# it's a good sign

glxinfo | grep -i vir
# it should show something like:
# Device: virgl ...
```

## References

<https://github.com/snapcore/snapd/blob/5c8d8431baa425464b279ff26b8c44eecb9aab22/interfaces/builtin/opengl.go#L41>

<https://gitlab.gnome.org/GNOME/gnome-boxes/-/issues/586>
