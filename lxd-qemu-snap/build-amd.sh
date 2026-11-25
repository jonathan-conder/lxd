#!/bin/bash
set -euo pipefail

snap_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="${snap_dir}/build"

instance=amd-rocm
kernel_release=7.0.0-44-rocm-virtio
render_node=/dev/dri/renderD128
rocm_version=7.14.0
rocm_gfx=gfx1150
venv=/opt/rocm-virtio

case "${1:-}" in
    kernel|rocr)
        if ! workshop info amd >/dev/null 2>&1; then
            workshop launch amd
        fi

        workshop run amd "build-$1"
        ;;

    install-snap)
        snapcraft pack
        snap="${snap_dir}/qemu-for-lxd_1_$(dpkg --print-architecture).snap"
        sudo snap install mesa-2604
        sudo snap install "${snap}" --devmode
        sudo snap connect lxd:gpu-2604 mesa-2604:gpu-2604
        sudo snap connect lxd:qemu-external qemu-for-lxd:qemu-external
        ;;

    uninstall-snap)
        sudo snap disconnect lxd:qemu-external
        sudo snap disconnect lxd:gpu-2604
        sudo snap remove qemu-for-lxd
        ;;

    vm)
        if ! lxc info "${instance}" >/dev/null 2>&1; then
            lxc init ubuntu:26.04 "${instance}" --vm \
                -c boot.mode=uefi-nosecureboot \
                -c limits.cpu=8 \
                -c limits.memory=16GiB \
                -d root,size=64GiB \
                -c raw.qemu="-display egl-headless,rendernode=${render_node}" \
                -c raw.qemu.conf='[device "qemu_gpu"]
driver = "virtio-vga-gl"
blob = "true"
hostmem = "16G"
rocm = "true"' \
                -c raw.apparmor='/snap/lxd/*/gpu-2604/** mr,
/dev/dri/ r,
/dev/dri/card[0-9]* rw,
/dev/dri/renderD[0-9]* rw,
/dev/kfd rw,
/run/udev/data/c226:[0-9]* r,
/sys/devices/** r,
/sys/bus/** r,'
        fi

        if ! lxc info "${instance}" | grep -q '^Status: RUNNING$'; then
            lxc start "${instance}"
        fi

        until lxc exec "${instance}" -- true 2>/dev/null; do
            sleep 1
        done

        arch="$(dpkg --print-architecture)"
        for package in linux-image-unsigned linux-modules; do
            lxc file push --create-dirs "${build_dir}/${package}-${kernel_release}_7.0.0-44.44_${arch}.deb" "${instance}/var/tmp/rocm-virtio/"
        done
        lxc exec "${instance}" -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y /var/tmp/rocm-virtio/*.deb'

        # Otherwise a newer stock kernel would boot first.
        lxc exec "${instance}" -- sh -c "echo 'GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux ${kernel_release}\"' > /etc/default/grub.d/99-rocm-virtio.cfg && update-grub"
        lxc restart "${instance}"

        until lxc exec "${instance}" -- true 2>/dev/null; do
            sleep 1
        done
        running="$(lxc exec "${instance}" -- uname -r)"
        if [ "${running}" != "${kernel_release}" ]; then
            printf '%s is running %s\n' "${instance}" "${running}"
            exit 1
        fi
        ;;

    pytorch)
        lxc exec "${instance}" -- sh -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv libgomp1 libelf1t64 libnuma-dev libdrm2 libdrm-amdgpu1'
        lxc exec "${instance}" -- python3 -m venv "${venv}"
        lxc exec "${instance}" -- "${venv}/bin/pip" install --index-url https://repo.amd.com/rocm/whl-multi-arch/ \
            "rocm[libraries,device-${rocm_gfx}]==${rocm_version}" \
            "torch[device-${rocm_gfx}]==2.12.0+rocm${rocm_version}" \
            "torchvision[device-${rocm_gfx}]==0.27.0+rocm${rocm_version}"
        lxc exec "${instance}" -- "${venv}/bin/pip" install accelerate diffusers transformers

        # Only ROCr changes; the stock wheels' HIP and PyTorch run unmodified on top.
        lib="$(lxc exec "${instance}" -- "${venv}/bin/python" -c 'import _rocm_sdk_core, pathlib; print(pathlib.Path(_rocm_sdk_core.__file__).parent / "lib")')"
        lxc file push --create-dirs "${build_dir}/libhsa-runtime64.so.1" "${instance}/var/tmp/rocm-virtio/"
        lxc exec "${instance}" -- cp /var/tmp/rocm-virtio/libhsa-runtime64.so.1 "${lib}/libhsa-runtime64.so.1"
        ;;

    test)
        shift
        lxc file push --create-dirs "${snap_dir}/rocm-test.py" "${instance}/var/tmp/rocm-virtio/"
        lxc exec "${instance}" -- "${venv}/bin/python" /var/tmp/rocm-virtio/rocm-test.py "$@"
        ;;

    *)
        echo "Usage: $0 {kernel|rocr|install-snap|uninstall-snap|vm|pytorch|test}" >&2
        exit 2
        ;;
esac
