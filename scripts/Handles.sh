#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/openwrt/package/"




#预置HomeProxy数据
if [ -d *"homeproxy"* ]; then
	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	git clone -q --depth=1 --single-branch --branch "release" "https://github.com/Loyalsoldier/surge-rules.git" ./$HP_RULE/
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd $PKG_PATH && echo "homeproxy date has been updated!"
fi

#移除Shadowsocks组件
PW_FILE=$(find ./ -maxdepth 3 -type f -wholename "*/luci-app-passwall/Makefile")
if [ -f "$PW_FILE" ]; then
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_Shadowsocks_Libev/,/x86_64/d' $PW_FILE
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR/,/default n/d' $PW_FILE
	sed -i '/Shadowsocks_NONE/d; /Shadowsocks_Libev/d; /ShadowsocksR/d' $PW_FILE

	cd $PKG_PATH && echo "passwall has been fixed!"
fi

SP_FILE=$(find ./ -maxdepth 3 -type f -wholename "*/luci-app-ssr-plus/Makefile")
if [ -f "$SP_FILE" ]; then
	sed -i '/default PACKAGE_$(PKG_NAME)_INCLUDE_Shadowsocks_Libev/,/libev/d' $SP_FILE
	sed -i '/config PACKAGE_$(PKG_NAME)_INCLUDE_ShadowsocksR/,/x86_64/d' $SP_FILE
	sed -i '/Shadowsocks_NONE/d; /Shadowsocks_Libev/d; /ShadowsocksR/d' $SP_FILE

	cd $PKG_PATH && echo "ssr-plus has been fixed!"
fi

#修复TailScale配置文件冲突
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	sed -i '/\/files/d' $TS_FILE

	cd $PKG_PATH && echo "tailscale has been fixed!"
fi

#临时修复 nss-firmware 校验不通过
cd "$pkgPath"
NSS_FIRMWARE_FILE="$WRT_MainPath/feeds/nss_packages/firmware/nss-firmware/Makefile"
if [ -f "$NSS_FIRMWARE_FILE" ]; then
 	sed -i 's/3ec87f221e8905d4b6b8b3d207b7f7c4666c3bc8db7c1f06d4ae2e78f863b8f4/881cbf75efafe380b5adc91bfb1f68add5e29c9274eb950bb1e815c7a3622807/g' "$NSS_FIRMWARE_FILE"
 	echo 'Fixed: nss-firmware'
 	echo ''
fi

# 修复 Rust 编译失败
cd "$pkgPath"
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE
	echo 'Fixed: rust'
	echo ''
fi

# 修复 DiskMan 编译失败
cd "$pkgPath"
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	sed -i 's/fs-ntfs/fs-ntfs3/g' $DM_FILE
	sed -i '/ntfs-3g-utils /d' $DM_FILE
	echo 'Fixed: diskman'
	echo ''
fi

# 修复 Coremark
cd "$pkgPath"
COREMARK_FILE="$WRT_MainPath/feeds/packages/utils/coremark/Makefile"
if [ -f "$COREMARK_FILE" ]; then
	sed -i 's/mkdir \$(PKG_BUILD_DIR)\/\$(ARCH)/mkdir -p \$(PKG_BUILD_DIR)\/\$(ARCH)/g' "$COREMARK_FILE"
	echo 'Fixed: coremark'
	echo ''
fi

# 删除 SB 内核回溯移植补丁
cd "$pkgPath"
SB_PATCH="../feeds/packages/net/sing-box/patches"
if [ -d "$SB_PATCH" ]; then
	rm -rf $SB_PATCH
	echo "Fixed: sing-box patches"
	echo ''
fi



