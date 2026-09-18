#!/bin/bash
set -u

# =============================================================================
# 【2026-09-18 修订】xray / sing-box 永远取最新，Go 工具链由 GoToolchain.sh 顶上去
# -----------------------------------------------------------------------------
# 事故回顾：xray-core 升到 v26.9.9（go.mod 要求 go 1.27），而本源码线（LiBwrt
#   25.12-nss，packages feed 钉在 immortalwrt/packages@84bd8638）的 Go 工具链只有
#   1.26.8，且 golang-package.mk 写死 GOTOOLCHAIN=local（不会自动下载新工具链）
#   → xray-core 编译失败。
#
# 第一版修复是「降级 xray 到 v26.7.28」，但那与「必须用最新 xray」的目标冲突。
# 现改为：本脚本只负责选版本（永远取最新），Go 工具链交给 scripts/GoToolchain.sh
#   按 xray / sing-box 的 go.mod 要求自动升级（会引入 golang1.27 包并切换默认 Go）。
#
# 因此这里对 xray / sing-box 关闭 Go 兼容性过滤（第 3 个参数传 no-go-filter）；
#   其余包（tailscale 等）仍保留过滤，避免在未升级 Go 时编出半成品。
#
# 事实依据（均可复现）：
#   * golang-package.mk:224  GOTOOLCHAIN=local
#   * Xray-core: v26.4.25 / v26.5.9 / v26.6.27 / v26.7.28 声明 go 1.26；
#                v26.9.8 / v26.9.9 起声明 go 1.27
#   * go1.27.0.src.tar.gz 实测 sha256 与 immortalwrt/packages@master 的
#     golang1.27/Makefile PKG_HASH 完全一致（见 GoToolchain.sh 注释）
# =============================================================================

GOLANG_BASE="../feeds/packages/lang/golang"

# 取本源码线真实的 Go 工具链版本（major.minor.patch）。
# 注意：golang-values.mk 的 GO_DEFAULT_VERSION 只有 major.minor（如 1.26），
#       真正的补丁号在 lang/golang/golang1.26/Makefile 的 GO_VERSION_PATCH（如 8）里，
#       合起来才是实际工具链 1.26.8 —— 漏掉补丁号会导致 tailscale 这类
#       "要求 go 1.26.6" 的包被误判为不可用。
detect_golang_version() {
	local mm patch
	[ -f "$GOLANG_BASE/golang-values.mk" ] || return 0
	mm=$(grep -m1 '^GO_DEFAULT_VERSION:=' "$GOLANG_BASE/golang-values.mk" 2>/dev/null | cut -d= -f2 | tr -d ' \r')
	[ -n "$mm" ] || return 0
	patch=$(grep -m1 '^GO_VERSION_PATCH:=' "$GOLANG_BASE/golang$mm/Makefile" 2>/dev/null | cut -d= -f2 | tr -d ' \r')
	if [ -n "$patch" ]; then
		printf '%s.%s' "$mm" "$patch"
	else
		printf '%s' "$mm"
	fi
}

GOLANG_MAX=$(detect_golang_version)
if [ -n "$GOLANG_MAX" ]; then
	echo "::notice::本源码线 Go 工具链 = $GOLANG_MAX（仅用于 tailscale 等非强制最新包的兼容过滤；xray/sing-box 由 GoToolchain.sh 负责升级 Go）"
else
	echo "::warning::未能识别 Go 工具链版本（$GOLANG_BASE 不存在），跳过 Go 兼容性过滤"
fi

# 读取某个 tag 的 go.mod 里声明的 Go 版本；非 Go 项目返回空
go_mod_requires() {
	local REPO=$1 TAG=$2
	curl -sfL --max-time 20 "https://raw.githubusercontent.com/$REPO/$TAG/go.mod" 2>/dev/null \
		| awk '/^go /{print $2; exit}'
}

# 版本号归一化：1.27 与 1.27.0 视为同一个版本
norm_ver() {
	local v=$1 a b c
	case "$v" in
		[0-9]*.[0-9]*) ;;
		*) printf '%s' "$v"; return ;;
	esac
	IFS=. read -r a b c <<<"$v"
	printf '%s.%s.%s' "${a:-0}" "${b:-0}" "${c:-0}"
}

# $1 <= $2 ?（用 sort -V 做版本比较，不依赖 dpkg，便于本地单测）
version_le() {
	local n1 n2
	n1=$(norm_ver "$1")
	n2=$(norm_ver "$2")
	[ "$(printf '%s\n%s\n' "$n1" "$n2" | sort -V | head -n 1)" = "$n1" ]
}

# 安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	# [修复7] set -u 下 $4 未传会崩；用默认值兜底
	local PKG_SPECIAL=${4:-}
	local REPO_NAME=$(echo $PKG_REPO | cut -d '/' -f 2)

	# [修复1] 用「后缀匹配」 *PKG_NAME 取代「包含匹配」 *PKG_NAME*
	#   原写法下 UPDATE_PACKAGE "passwall" 会命中并删除刚克隆的 ./passwall-packages，
	#   导致 openwrt-passwall-packages 里的 sing-box / xray-core / geoview / geodata 全部丢失。
	#   -iname "*passwall"  命中 luci-app-passwall   （这是本意）
	#   -iname "*passwall"  不命中 passwall-packages （这是修复点）
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
# $1 包名 / $2 是否允许预发布（true|not）/ $3 是否按 Go 工具链过滤（yes|no-go-filter）
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-not}
	local PKG_GO_FILTER=${3:-yes}
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
		# [修订 2026-09-18] token 为空时绝不能发 "Authorization: Bearer "，
		#   那会被判 Bad credentials 返回 401，curl -f 直接失败；此时应完全不带该头。
		local PKG_API
		if [ -n "${GITHUB_TOKEN:-}" ]; then
			PKG_API=$(curl -sfL --max-time 30 \
				-H "Authorization: Bearer ${GITHUB_TOKEN}" \
				-H "X-GitHub-Api-Version: 2022-11-28" \
				"https://api.github.com/repos/$PKG_REPO/releases?per_page=50")
		else
			PKG_API=$(curl -sfL --max-time 30 \
				-H "X-GitHub-Api-Version: 2022-11-28" \
				"https://api.github.com/repos/$PKG_REPO/releases?per_page=50")
		fi
		if [ -z "$PKG_API" ]; then
			echo "::warning::[$PKG_NAME] GitHub API 请求失败（限流或网络），跳过"
			continue
		fi

		# [修订 2026-09-18] 选版本策略：
		#   * no-go-filter（xray / sing-box）：直接取列表中最新的一个，所需 Go 由
		#     GoToolchain.sh 负责顶上去 —— 满足「必须用最新版」的硬需求。
		#   * 默认 yes：由新到旧扫描，取第一个 go.mod 要求 <= 本 feed 工具链的版本，
		#     避免在 Go 未升级时编出半成品（tailscale 等走这条路）。
		local PKG_VER=""
		local CANDIDATE REQ
		for CANDIDATE in $(echo "$PKG_API" | jq -r "map(select(.prerelease|$PKG_MARK)) | .[].tag_name"); do
			if [ "$PKG_GO_FILTER" = "no-go-filter" ]; then
				PKG_VER=$CANDIDATE
				break
			fi
			REQ=$(go_mod_requires "$PKG_REPO" "$CANDIDATE")
			if [ -z "$REQ" ] || [ -z "$GOLANG_MAX" ] || version_le "$REQ" "$GOLANG_MAX"; then
				PKG_VER=$CANDIDATE
				break
			fi
			echo "  跳过 $CANDIDATE（go.mod 要求 go $REQ > 工具链 $GOLANG_MAX）"
		done

		if [ -z "$PKG_VER" ]; then
			echo "::warning::[$PKG_NAME] 未匹配到可用 release（$PKG_REPO）"
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

#UPDATE_VERSION "软件包名" "是否允许预发布版，true，可选，默认只取正式版" "是否按 Go 工具链过滤，no-go-filter，可选"
#
# [修订 2026-09-18] xray / sing-box 关闭 Go 兼容性过滤 → 永远取最新版。
#   所需 Go 工具链由紧随其后的 scripts/GoToolchain.sh 自动升级（引入 golang1.27 并切换
#   默认 Go），因此这里不需要再为「能不能编」而牺牲版本。
#   Xray 从 v26.4 起把 release 全部标记为 prerelease，故必须传 "true"，
#   否则会永远停在 v26.3.27（与 feed 同版，"更新"形同虚设）。
UPDATE_VERSION "sing-box" "not" "no-go-filter"
UPDATE_VERSION "xray-core" "true" "no-go-filter"

# tailscale 保留 Go 过滤：它不是必追最新的组件，Go 不满足时停在可编译版本更稳
UPDATE_VERSION "tailscale"
