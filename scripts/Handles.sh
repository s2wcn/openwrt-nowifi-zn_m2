#!/bin/bash
set -u

# [修复0] WRT_MainPath 在全仓库从未定义过。
#   原脚本里 $WRT_MainPath/feeds/... 会被展开成 /feeds/...（根目录），
#   在 Runner 上创建失败 → 整段逻辑静默失效（nss-firmware 修复、golang 更新全部没跑）。
#   core.yml 里已显式导出该变量，这里保留兜底，避免哪天 env 漏了又静默失效。
WRT_MainPath="${WRT_MainPath:-${OPENWRT_PATH:-/workdir/openwrt}}"
PKG_PATH="$GITHUB_WORKSPACE/openwrt/package/"

if [ ! -d "$WRT_MainPath" ]; then
	echo "::error::WRT_MainPath ($WRT_MainPath) 不存在"
	exit 1
fi


#预置HomeProxy数据
# [修复1] 原写法 [ -d *"homeproxy"* ] 未加引号，若匹配到多个目录会报 "too many arguments"
shopt -s nullglob
HP_DIRS=( ./homeproxy* )
shopt -u nullglob
if [ ${#HP_DIRS[@]} -gt 0 ]; then
	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" ./$HP_RULE/ || exit 1
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd "$PKG_PATH" && echo "homeproxy date has been updated!"
fi

#移除Shadowsocks组件
# [修复2] sed 前先确认目标行存在，避免上游改名后"以为改了其实没改"
PW_FILE=$(find ./ -maxdepth 3 -type f -wholename "*/luci-app-passwall/Makefile")
if [ -f "$PW_FILE" ]; then
	# 注意：upstream 已把 Shadowsocks_Libev 改名为 ShadowsocksR_Libev_Client/Server，
	# 下面第 1 条规则已失效，保留仅为兼容旧版；第 2、3 条靠前缀 ShadowsocksR 命中。
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_Shadowsocks_Libev/,/x86_64/d' $PW_FILE
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR/,/default n/d' $PW_FILE
	sed -i '/Shadowsocks_NONE/d; /Shadowsocks_Libev/d; /ShadowsocksR/d' $PW_FILE

	if grep -q "Shadowsocks" "$PW_FILE"; then
		echo "::warning::passwall Makefile 仍存在 Shadowsocks 残留，请检查 sed 规则是否过期"
	fi

	cd "$PKG_PATH" && echo "passwall has been fixed!"
else
	echo "::warning::未找到 luci-app-passwall/Makefile，跳过 Shadowsocks 清理"
fi

SP_FILE=$(find ./ -maxdepth 3 -type f -wholename "*/luci-app-ssr-plus/Makefile")
if [ -f "$SP_FILE" ]; then
	sed -i '/default PACKAGE_$(PKG_NAME)_INCLUDE_Shadowsocks_Libev/,/libev/d' $SP_FILE
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR/,/x86_64/d' $SP_FILE
	sed -i '/Shadowsocks_NONE/d; /Shadowsocks_Libev/d; /ShadowsocksR/d' $SP_FILE

	cd "$PKG_PATH" && echo "ssr-plus has been fixed!"
fi

#修复TailScale配置文件冲突
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	sed -i '/\/files/d' $TS_FILE

	cd "$PKG_PATH" && echo "tailscale has been fixed!"
fi

# 修复 luci-app-openvpn-server 配置文件冲突
OPENVPN_SERVER_MK=$(find ./ -maxdepth 5 -type f -wholename "*/luci-app-openvpn-server/Makefile")
if [ -f "$OPENVPN_SERVER_MK" ]; then
	sed -i '/INSTALL_DATA.*files\/etc\/config\/openvpn.*etc\/config\/openvpn/{
s|.*|	# 仅在不存在时安装配置文件\\\
	if [ ! -f \\$(1)/etc/config/openvpn ]; then \\\
		\\$(INSTALL_DATA) ./files/etc/config/openvpn \\$(1)/etc/config/openvpn; \\\
	fi|
}' "$OPENVPN_SERVER_MK"
	echo "Fixed: luci-app-openvpn-server config conflict"
	echo ''
fi

#临时修复 nss-firmware 校验不通过
cd "$PKG_PATH"
NSS_FIRMWARE_FILE="$WRT_MainPath/feeds/nss_packages/firmware/nss-firmware/Makefile"
if [ -f "$NSS_FIRMWARE_FILE" ]; then
	# [修复3] 先确认旧哈希确实存在再替换，否则上游更新后这条 sed 会变成无意义的 no-op
	if grep -q "3ec87f221e8905d4b6b8b3d207b7f7c4666c3bc8db7c1f06d4ae2e78f863b8f4" "$NSS_FIRMWARE_FILE"; then
		sed -i 's/3ec87f221e8905d4b6b8b3d207b7f7c4666c3bc8db7c1f06d4ae2e78f863b8f4/881cbf75efafe380b5adc91bfb1f68add5e29c9274eb950bb1e815c7a3622807/g' "$NSS_FIRMWARE_FILE"
		echo 'Fixed: nss-firmware'
	else
		echo "::warning::nss-firmware 旧哈希未命中，补丁可能已过期，请人工确认"
	fi
	echo ''
fi

# 修复 Rust 编译失败
cd "$PKG_PATH"
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE
	echo 'Fixed: rust'
	echo ''
fi

# 修复 DiskMan 编译失败
cd "$PKG_PATH"
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	sed -i 's/fs-ntfs/fs-ntfs3/g' $DM_FILE
	sed -i '/ntfs-3g-utils /d' $DM_FILE
	echo 'Fixed: diskman'
	echo ''
fi

# 修复 libffi 3.4.7 缺失 fficonfig.h 编译失败
cd "$PKG_PATH"
LIBFFI_MK=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/libffi/Makefile")
if [ -f "$LIBFFI_MK" ]; then
	sed -i 's|[^[:space:]]*fficonfig\.h|$(PKG_INSTALL_DIR)/usr/include/ffi.h|g' "$LIBFFI_MK"
	echo 'Fixed: libffi missing fficonfig.h by replacing target file'
	echo ''
fi

# =============================================================================
# 更新 Golang —— 建议【整段删除】
# -----------------------------------------------------------------------------
# 实测（2026-09-05）：
#   * immortalwrt/packages 默认 Go  = 1.27   （feeds/packages/lang/golang/golang-values.mk）
#   * sbwml/packages_lang_golang 25.x = 1.25.14
#   * sbwml/packages_lang_golang 26.x = 1.26.8
#   * xray-core >= v26.1 的 go.mod 要求 go >= 1.26
#   * sing-box  v1.14.0  的 go.mod 要求 go >= 1.25.5
#
# 也就是说：原脚本用 25.x 覆盖，会把 Go 从 1.27 降到 1.25.14，
# xray-core 会直接编译失败（go.mod requires go >= 1.26）。
# feeds 自带的 1.27 已经比 sbwml 的任何分支都新，这段覆盖没有任何收益，只有风险。
#
# 如果你确实需要固定到某个版本（例如上游 feed 哪天回退了），用下面的写法，
# 并且只能用 26.x 及以上的分支：
#
# cd "$PKG_PATH"
# GOLANG_DIR="$WRT_MainPath/feeds/packages/lang/golang"
# if [ -d "$GOLANG_DIR" ]; then
# 	rm -rf "$GOLANG_DIR"
# 	# 注意：sbwml 仓库根目录 == immortalwrt 的 lang/golang/ 目录
# 	# （含 golang/ 子目录 + golang-*.mk），所以整仓克隆覆盖到 lang/golang 是正确结构
# 	git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang "$GOLANG_DIR" || exit 1
# 	echo 'Updated: golang -> 1.26.8'
# fi
# =============================================================================
