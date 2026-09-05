#!/bin/bash
set -u

# 安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local REPO_NAME=$(echo $PKG_REPO | cut -d '/' -f 2)

	# [修复1] 用「后缀匹配」 *PKG_NAME 取代「包含匹配」 *PKG_NAME*
	#   原写法下 UPDATE_PACKAGE "passwall" 会命中并删除刚克隆的 ./passwall-packages，
	#   导致 openwrt-passwall-packages 里的 sing-box / xray-core / geoview / geodata 全部丢失。
	#   -iname "*passwall"  命中 luci-app-passwall   ✅（这是本意）
	#   -iname "*passwall"  不命中 passwall-packages ✅（这是修复点）
	rm -rf $(find ./ ../feeds/luci/ ../feeds/packages/ -maxdepth 5 -type d -iname "*$PKG_NAME" -prune)

	# [修复2] 克隆失败必须让 CI 变红，否则上游改分支名/删仓库后会静默编译出缺件固件
	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" \
		|| { echo "::error::git clone $PKG_REPO ($PKG_BRANCH) failed"; exit 1; }

	if [[ $PKG_SPECIAL == "pkg" ]]; then
		cp -rf $(find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune) ./
		rm -rf ./$REPO_NAME/
	elif [[ $PKG_SPECIAL == "name" ]]; then
		mv -f $REPO_NAME $PKG_NAME
	fi
}

#UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg/name，可选，pkg为从大杂烩中单独提取包名插件；name为重命名为包名"
UPDATE_PACKAGE "argon" "jerrykuku/luci-theme-argon" "master"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "js"

UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"

# [修复3] passwall / passwall2 先跑，passwall-packages 最后跑（纵深防御，配合修复1 双保险）
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"
UPDATE_PACKAGE "passwall-packages" "Openwrt-Passwall/openwrt-passwall-packages" "main"

UPDATE_PACKAGE "alist" "sbwml/luci-app-alist" "main"
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5"
UPDATE_PACKAGE "vnt" "lazyoop/networking-artifact" "main" "pkg"
UPDATE_PACKAGE "easytier" "lazyoop/networking-artifact" "main" "pkg"

UPDATE_PACKAGE "luci-app-gecoosac" "lyin888/openwrt-gecoosac" "main"
UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"

# UPDATE_PACKAGE "luci-app-ddns-go" "sirpdboy/luci-app-ddns-go" "main"
# UPDATE_PACKAGE "luci-app-msd_lite" "ximiTech/luci-app-msd_lite" "main"


# 更新软件包版本
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-not}
	local PKG_FILES=$(find ./ ../feeds/packages/ -maxdepth 5 -type f -wholename "*/$PKG_NAME/Makefile")

	echo " "

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo "$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Pho 'PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)' $PKG_FILE | head -n 1)

		# [修复4] 带 Token 调用 GitHub API。
		#   匿名调用限流 60 次/小时，Runner 共享出口 IP 经常被打满，
		#   原代码失败后 PKG_VER 为空 → 静默跳过更新，你以为是最新的其实不是。
		local PKG_API=$(curl -sfL \
			-H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"https://api.github.com/repos/$PKG_REPO/releases?per_page=50")
		if [ -z "$PKG_API" ]; then
			echo "::warning::[$PKG_NAME] GitHub API 请求失败（限流或网络），跳过"
			continue
		fi

		local PKG_VER=$(echo "$PKG_API" | jq -r "map(select(.prerelease|$PKG_MARK)) | first | .tag_name // empty")
		if [ -z "$PKG_VER" ]; then
			echo "::warning::[$PKG_NAME] 未匹配到 release（$PKG_REPO）"
			continue
		fi

		local NEW_VER=$(echo $PKG_VER | sed "s/.*v//g; s/_/./g")
		local NEW_HASH=$(curl -sfL "https://codeload.github.com/$PKG_REPO/tar.gz/$PKG_VER" | sha256sum | cut -b -64)
		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")

		# [修复5] 校验哈希长度，避免把 404 页面的哈希写进 Makefile
		if [[ ! "$NEW_HASH" =~ ^[0-9a-f]{64}$ ]]; then
			echo "::warning::[$PKG_NAME] 源码包下载失败，跳过（$PKG_VER）"
			continue
		fi

		echo "$OLD_VER -> $PKG_VER ($NEW_VER) $NEW_HASH"

		if [[ $NEW_VER =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "::notice::$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}

#UPDATE_VERSION "软件包名" "是否允许预发布版，true，可选，默认只取正式版"
UPDATE_VERSION "sing-box"

# [修复6] Xray 从 v26.4.x 起把 release 全部标记为 prerelease，
#   只取正式版会永远停在 v26.3.27（与 immortalwrt feeds 一致，"更新"形同虚设）。
#   传 true 可拿到真正的 v26.7.28；代价是它是预发布版，且要求 go >= 1.26
#   （immortalwrt 默认 Go 1.27 满足，但千万别被 golang 覆盖块降到 25.x）。
UPDATE_VERSION "xray-core" "true"
UPDATE_VERSION "tailscale"
