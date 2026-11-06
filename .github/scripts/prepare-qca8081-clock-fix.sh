#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIX="$PROJECT_ROOT/Patches/qualcommax-qca8081-clock-fix.patch"
DRIVER=target/linux/qualcommax/files/drivers/net/ethernet/qualcomm/qca_ppe_main.c

# The SSDK/NSS trees have a different clock driver and must not receive this
# PPE-specific backport. Both PURE and PLUS use this same preparation step.
if [[ ! -f "$DRIVER" ]]; then
    if [[ "${GITHUB_ACTIONS:-false}" == "true" || "${CI:-false}" == "true" ]]; then
        echo 'QCA8081 clock fix: missing Qualcomm PPE driver in CI environment; refusing build.' >&2
        exit 1
    else
        echo 'QCA8081 clock fix: no Qualcomm PPE driver; skipping.'
        exit 0
    fi
fi
if ! grep -Eq '^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*6\.18[[:space:]]*$' target/linux/qualcommax/Makefile; then
    echo 'QCA8081 clock fix: unsupported PPE kernel; review the backport before building.' >&2
    exit 1
fi

# 新源码的 0085 已经加入四个分频项，0919 只需调整优先级。
UPSTREAM_0085=target/linux/qualcommax/patches-6.18/0085-clk-qcom-gcc-ipq8074-add-port5-sgmii-rates.patch
if [[ -f "$UPSTREAM_0085" ]]; then
    if [[ "$(git hash-object --path="$UPSTREAM_0085" "$UPSTREAM_0085")" != f8ac1df641b9075cf993170582ffe0e449306060 ]]; then
        echo '上游 0085 已变更，请重新核对 IPQ8074 的分频补丁。' >&2
        exit 1
    fi
    SERIES=$(mktemp)
    trap 'rm -f "$SERIES"' EXIT
    # 替换 0919 的外层补丁，0918 与 PPE 驱动仍参与同一次原子预检。
    awk '/^diff --git / { skip = ($4 ~ /\/0919-clk-qcom-gcc-ipq8074-/) } !skip' "$FIX" > "$SERIES"
    cat "$PROJECT_ROOT/Patches/qualcommax-ipq8074-after-0085.patch" >> "$SERIES"
    FIX="$SERIES"
fi

# Check the whole series first: a conflict must not leave just the clock
# tables or just the parent selection applied to a changing upstream tree.
if git apply --check "$FIX" 2>/dev/null; then
    # Preserve whitespace in the embedded GCC patch context verbatim.
    git apply --whitespace=nowarn "$FIX"
    echo 'QCA8081 clock fix: applied PPE parent selection and GCC frequency tables.'
elif git apply --reverse --check "$FIX" 2>/dev/null; then
    echo 'QCA8081 clock fix: complete backport already present.'
else
    echo 'QCA8081 clock fix: source drift or partial backport; refusing an unverified build.' >&2
    git apply --check "$FIX" >&2
    exit 1
fi
