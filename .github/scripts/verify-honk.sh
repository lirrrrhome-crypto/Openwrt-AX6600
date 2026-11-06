#!/usr/bin/env bash
# 从 ImmortalWrt 编译根目录运行。所有检查均针对本次构建。
set -euo pipefail

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }

shopt -s nullglob
btf_path=usr/lib/debug/boot/vmlinux
kernel_binary() {
    local kernels=(build_dir/target-*/linux-qualcommax_ipq60xx/linux-*/vmlinux)
    [[ ${#kernels[@]} == 1 ]] || fail '无法唯一确定本次编译的内核'
    printf '%s\n' "${kernels[0]}"
}

case "${1:-}" in
    config)
        profile="$GITHUB_WORKSPACE/Config/GENERAL_AX6600_HONK.txt"
        while IFS= read -r line; do
            case "$line" in
                CONFIG_*=y|'# CONFIG_'*' is not set')
                    grep -Fxq -- "$line" .config || fail "最终配置缺少 $line"
                    ;;
            esac
        done < "$profile"
        grep -Fxq 'CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-02=y' .config ||
            fail '目标设备未选中雅典娜 RE-CS-02'
        ;;
    btf)
        kernel=$(kernel_binary)
        mkdir -p "files/${btf_path%/*}"
        pahole --btf_encode_detached="files/$btf_path" "$kernel"
        # 核验小端 BTF 头、类型区与字符串区的边界，防止空文件进入镜像。
        python3 - "files/$btf_path" <<'PY'
import struct
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
magic, version, _, header, types, size, strings, length = struct.unpack_from("<HBBIIIII", data)
if (magic != 0xeb9f or version != 1 or header < 24 or size == 0 or length == 0
        or types + size > strings or header + strings + length > len(data)):
    sys.exit("生成的独立 BTF 数据不完整")
PY
        sha256sum "files/$btf_path"
        ;;
    image)
        kernel=$(kernel_binary)
        kernel_dir=${kernel%/*}
        for symbol in BPF BPF_SYSCALL BPF_JIT CGROUP_BPF NET_SCHED NET_CLS_ACT NET_XGRESS NET_NS; do
            grep -Fxq "CONFIG_$symbol=y" "$kernel_dir/.config" || fail "实际内核缺少 CONFIG_$symbol=y"
        done
        for symbol in NF_TABLES NF_TABLES_INET NFT_CT NFT_QUEUE NETFILTER_NETLINK_QUEUE; do
            grep -Eq "^CONFIG_$symbol=[ym]$" "$kernel_dir/.config" || fail "实际内核缺少 CONFIG_$symbol"
        done
        target=bin/targets/qualcommax/ipq60xx
        manifests=("$target"/*.manifest)
        [[ ${#manifests[@]} == 1 ]] || fail '无法唯一确定雅典娜的包清单'
        for package in honk luci-app-honk kmod-sched-core kmod-sched-bpf kmod-veth kmod-nft-queue v2ray-geoip v2ray-geosite; do
            grep -Eq "^$package[[:space:]]+-[[:space:]]" "${manifests[0]}" || fail "镜像清单缺少 $package"
        done
        factory=("$target"/*jdcloud_re-cs-02*factory.bin)
        upgrade=("$target"/*jdcloud_re-cs-02*sysupgrade.bin)
        [[ ${#factory[@]} == 1 && ${#upgrade[@]} == 1 ]] || fail '缺少雅典娜的首次刷入或升级镜像'

        # 厂商布局固定为 6144 KiB 内核槽；BTF 增大内核后，根分区必须仍在原偏移。
        members=$(tar -tf "${upgrade[0]}")
        member=$(grep -E '^([^/]+/)+kernel$' <<< "$members") || fail '升级镜像中没有内核'
        kernel_size=$(tar -xOf "${upgrade[0]}" "$member" | wc -c)
        (( kernel_size > 0 && kernel_size <= 6144 * 1024 )) || fail "内核大小 $kernel_size 字节超出固定槽位"
        magic=$(dd if="${factory[0]}" bs=1 skip=$((6144 * 1024)) count=4 status=none)
        [[ "$magic" == hsqs ]] || fail '首次刷入镜像的根文件系统偏移异常'
        # 核对两份成品内的 BTF 与本次内核生成的数据逐字节一致。
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT
        dd if="${factory[0]}" of="$temp_dir/root.squashfs" bs=1M skip=6 status=none
        unsquashfs -cat "$temp_dir/root.squashfs" "$btf_path" | cmp - "files/$btf_path"
        root_member=$(grep -E '^([^/]+/)+root$' <<< "$members") || fail '升级镜像中没有根文件系统'
        tar -xOf "${upgrade[0]}" "$root_member" > "$temp_dir/root.squashfs"
        unsquashfs -cat "$temp_dir/root.squashfs" "$btf_path" | cmp - "files/$btf_path"
        printf '镜像验收通过，内核占用 %s / 6291456 字节。\n' "$kernel_size"
        ;;
    *) fail '请指定 config、btf 或 image' ;;
esac
