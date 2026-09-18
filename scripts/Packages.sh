#!/bin/bash
set -u

# =============================================================================
# 自定义包克隆 + 版本更新（2026-09-18 精简版：只保留 passwall 组）
# -----------------------------------------------------------------------------
# 【本次精简依据】config/libWrt/nowifiV2.config 实测（CONFIG_ALL 未开，未选中的包
#   不会进固件），逐符号核对结果：
#
#   ✅ 会编进固件（必须克隆）：
#        luci-app-passwall = y            ← Openwrt-Passwall/openwrt-passwall
#        xray-core         = y
#        sing-box          = y
#        geoview           = y
#        chinadns-ng       = y
#        dns2socks         = y
#        microsocks        = y
#        tcping            = y
#        xray-plugin       = y            ← 以上 8 个均由 openwrt-passwall-packages 提供
#
#   ❌ 未选中（已删除克隆，纯属死重量，且每个都是「上游删分支就卡死构建」的隐患）：
#        argon / kucat / nikki / alist / mosdns / vnt / easytier / gecoosac /
#        luci-app-tailscale / passwall2
#      实测：luci-app-passwall2 <未出现在配置中>；tailscale / mosdns 均为 not set；
#            luci-theme-argon not set；其余 <未出现在配置中>。
#      需要某个包时，把对应 UPDATE_PACKAGE 行加回来即可（分支名先在 GitHub 上确认）。
#
#   另注：luci-app-ddns-go = y，但它来自 immortalwrt/luci feed（实测 HTTP 200），
#         不需要克隆，故不在此脚本中。
#
# 【历史事故回顾】
#   1) UPDATE_PACKAGE "passwall" 的 rm 通配符是 "*passwall*"，会命中并删除刚克隆的
#      ./passwall-packages → xray-core / sing-box / geoview 全部丢失。已改为后缀匹配
#      "*passwall"，并把 passwall-packages 放到最后克隆（双保险）。
#   2) xray-core 曾被升到 v26.9.9（go.mod 要求 go 1.27），而本源码线
#      （LiBwrt 25.12-nss，packages feed 钉在 immortalwrt/packages@84bd8638）的 Go
#      工具链只有 1.26.8，且 golang-package.mk 写死 GOTOOLCHAIN=local（不会自动下载
#      新工具链）→ xray-core 编译失败。
#      现在：本脚本只负责「永远取最新版」，Go 工具链交给紧随其后的
#      scripts/GoToolchain.sh 按 xray / sing-box 的 go.mod 要求自动升级。
# =============================================================================

# 安装和更新软件包
# $1 匹配关键字（必须与克隆出的目录名后缀一致）
# $2 仓库 owner/name
# $3 分支
# $4 可选：pkg = 从大杂烩仓库里只提取匹配的包目录；name = 把目录重命名为关键字
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	# set -u 下 $4 未传会崩，用默认值兜底
	local PKG_SPECIAL=${4:-}
	local REPO_NAME=$(echo $PKG_REPO | cut -d '/' -f 2)

	# [修复1] 用「后缀匹配」 *PKG_NAME 取代「包含匹配」 *PKG_NAME*
	#   -iname "*passwall"  命中 luci-app-passwall   （这是本意）
	#   -iname "*passwall"  不命中 passwall-packages （这是修复点）
	# [优化] 原来是 rm -rf $(find ...)：无匹配时 find 返回空 → rm 报 "missing operand"
	#   虽不致命但污染日志。改用 -exec，天然处理「零匹配」。
	find ./ ../feeds/luci/ ../feeds/packages/ -maxdepth 5 -type d -iname "*$PKG_NAME" -prune \
		-exec rm -rf {} + 2>/dev/null || true

	# [修复2] 克隆失败必须让 CI 变红，否则上游改分支名/删仓库后会静默编译出缺件固件。
	# [修复14] 失败时顺便列出该仓库【现有的分支】，让「填哪个分支」不用再猜。
	#   事故背景：kucat 的 js 分支被上游删除 → 只报 "Remote branch js not found"，
	#   还得手工去 GitHub 网页翻。现在日志里直接给出候选分支。
	if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"; then
		echo "::error::git clone $PKG_REPO ($PKG_BRANCH) failed —— 分支或仓库可能已被上游删除/改名"
		echo "---------- $PKG_REPO 现有分支 ----------"
		git ls-remote --heads "https://github.com/$PKG_REPO.git" 2>/dev/null \
			| sed 's#.*refs/heads/#  #' || echo "  （无法读取，仓库可能已删除或私有）"
		echo "---------- 处理办法 ----------"
		echo "  在 scripts/Packages.sh 里把这一行改成上面存在的分支："
		echo "    UPDATE_PACKAGE \"$PKG_NAME\" \"$PKG_REPO\" \"<以上某个分支>\""
		echo "  注意第 1 个参数是匹配关键字（如 passwall），必须与包目录名后缀一致。"
		exit 1
	fi

	if [[ $PKG_SPECIAL == "pkg" ]]; then
		cp -rf $(find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune) ./
		rm -rf ./$REPO_NAME/
	elif [[ $PKG_SPECIAL == "name" ]]; then
		mv -f $REPO_NAME $PKG_NAME
	fi
}

# -----------------------------------------------------------------------------
# 自定义包克隆（只保留 passwall 组）
# -----------------------------------------------------------------------------
# 顺序很关键：passwall-packages 必须最后克隆。
#   若先克隆它，紧接着的 UPDATE_PACKAGE "passwall" 的 rm 通配符（后缀匹配）虽已修好
#   不会误删，但把 packages 放最后可做到「纵深防御」——任何未来的通配符改动都不会波及它。
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE "passwall-packages" "Openwrt-Passwall/openwrt-passwall-packages" "main"


# 更新软件包版本
# $1 包名（= feeds 里的包目录名）
# $2 是否允许预发布：true | not（默认 not，只取正式版）
# 说明：不再做 Go 兼容性过滤。xray / sing-box 的所需 Go 由 scripts/GoToolchain.sh
#       负责顶上去（Go 不够时它会明确报错退出，不会静默编出旧组件）。
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
		# [修订] token 为空时绝不能发 "Authorization: Bearer "，
		#   那会被判 Bad credentials 返回 401，curl -f 直接失败；此时应完全不带该头。
		#
		# [修复16 2026-09-18] 响应截断防护（实测踩到的真 bug）：
		#   Xray-core 的 release body 极长，per_page=50 时响应达 6.77 MB；
		#   配合 --max-time 30，在出口带宽抖动的 Runner 上会中途断流 → JSON 被截断
		#   → jq 报 "Unfinished string at EOF" → PKG_VER 为空 → 静默跳过更新，
		#   最终固件里的 xray 还是旧版（正是最该避免的失败模式）。
		#   四道防护：
		#     1) per_page 降到 20（2.7 MB，含最新版足够）——实测 Xray 第一条即 v26.9.9
		#     2) --compressed：GitHub 支持 gzip，实测传输耗时 7s → 3s
		#     3) max-time 放宽到 60
		#     4) 解析前先用 jq -e 校验 JSON 完整性，不完整则重试（最多 3 轮）
		#   注意只保留「外层重试」这一层，不再叠加 curl --retry，否则最坏 3×3 次
		#   请求会把这一步拖到十几分钟。
		local PKG_API=""
		local ATTEMPT
		for ATTEMPT in 1 2 3; do
			if [ -n "${GITHUB_TOKEN:-}" ]; then
				PKG_API=$(curl -sfL --compressed --max-time 60 \
					-H "Authorization: Bearer ${GITHUB_TOKEN}" \
					-H "X-GitHub-Api-Version: 2022-11-28" \
					"https://api.github.com/repos/$PKG_REPO/releases?per_page=20")
			else
				PKG_API=$(curl -sfL --compressed --max-time 60 \
					-H "X-GitHub-Api-Version: 2022-11-28" \
					"https://api.github.com/repos/$PKG_REPO/releases?per_page=20")
			fi
			# JSON 完整性校验：截断的响应也能过 curl 的退出码，必须让 jq 先验一遍
			if [ -n "$PKG_API" ] && printf '%s' "$PKG_API" | jq -e . >/dev/null 2>&1; then
				break
			fi
			PKG_API=""
			if [ "$ATTEMPT" -lt 3 ]; then
				echo "  [$PKG_NAME] 第 $ATTEMPT 次获取失败或响应不完整，3 秒后重试…"
				sleep 3
			fi
		done
		if [ -z "$PKG_API" ]; then
			# 说明：这里用 warning 而非 error，是不想让一次网络抖动直接掐掉整条
			# 2 小时的编译；真正的硬闸门在 GoToolchain.sh —— 它取不到组件 go.mod
			# 要求时会 ::error:: 退出，因此不会出现「Go 升了但组件没升」的静默错配。
			echo "::warning::[$PKG_NAME] GitHub API 请求失败或响应被截断（已重试 3 次），本次跳过版本更新"
			continue
		fi

		# 取列表中第一个符合 prerelease 策略的版本（= 最新）
		local PKG_VER=$(echo "$PKG_API" | jq -r "map(select(.prerelease|$PKG_MARK)) | first | .tag_name" | tr -d '\r')

		if [ -z "$PKG_VER" ] || [ "$PKG_VER" = "null" ]; then
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

#UPDATE_VERSION "软件包名" "是否允许预发布版，true，可选，默认只取正式版"
#
# 只更新 passwall 依赖链上的两个 Go 组件：
#   * xray-core 必须传 "true"：Xray 从 v26.4 起把 release 全部标记为 prerelease，
#     只取正式版会永远停在 v26.3.27（与 feed 同版，"更新"形同虚设）。
#   * sing-box 只取正式版，避免把 alpha 引入生产固件。
# （passwall 本体走 git 克隆拿 main 分支最新，无需走 release 更新。）
UPDATE_VERSION "sing-box" "not"
UPDATE_VERSION "xray-core" "true"
