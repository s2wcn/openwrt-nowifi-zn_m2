#!/bin/bash
set -eu

# =============================================================================
# 【2026-09-18 新增】Go 工具链自动跟随 xray / sing-box 版本
# -----------------------------------------------------------------------------
# 背景
#   xray-core 从 v26.9.8 起把 go.mod 的最低要求提到 go 1.27，而本源码线
#   （LiBwrt/openwrt-6.x@25.12-nss，packages feed 钉在 immortalwrt/packages@84bd8638）
#   的 Go 工具链是 1.26.8；同时 golang-package.mk 写死 GOTOOLCHAIN=local，
#   Go 不会自动下载更高工具链 → xray-core 必然编译失败（2026-09-18 事故）。
#
# 策略
#   以「最新 xray / sing-box 的 go.mod 声明」为唯一依据，自动把 feeds 的默认 Go 顶上去：
#     1) 工具链已满足         → 什么都不做
#     2) 需要更高 Go          → 优先用本仓库自带的 scripts/golangX.Y 副本；
#                               副本缺失则从 immortalwrt/packages@master 拉取
#     3) 上游也没有该 Go 版本 → 明确报错退出（绝不静默降级成旧组件）
#
# 为什么只改 1 行就能切换整条 Go 生态
#   feeds/packages/lang/golang/golang 是一个 dummy 包：
#       PKG_VERSION := $(GO_DEFAULT_VERSION)
#       HOST_BUILD_DEPENDS := golang$(PKG_VERSION)/host
#   所有写 PKG_BUILD_DEPENDS:=golang/host 的包（xray-core / sing-box / tailscale /
#   v2ray-core / mosdns ...）都会跟随 GO_DEFAULT_VERSION，所以把
#   golang-values.mk 的 GO_DEFAULT_VERSION 改成 1.27，全生态即整体切换。
#
# 实例自检（上游事实，均可复现）
#   * go1.27.0.src.tar.gz 实测 sha256 = 7002403d7cc44529ef6d26f69a44818263395ead7c16c05a5808ae047ebeb0e5
#     与 golang1.27/Makefile 的 PKG_HASH 完全一致
#   * golang-bootstrap 为 Go 1.24.13，足以引导 Go 1.27.0
#   * golang-values.mk 在 pin 与 master 之间只差 GO_DEFAULT_VERSION 这 1 行；
#     golang-package.mk / golang-build.sh / golang-compiler.mk / golang-host-build.mk
#     逐字节一致 → 移植风险极低
#
# 运行前提：已执行 ./scripts/feeds update -a && ./scripts/feeds install -a；已装 jq/curl
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRT_MAIN="${WRT_MainPath:-${OPENWRT_PATH:-/workdir/openwrt}}"
GOLANG_DIR="$WRT_MAIN/feeds/packages/lang/golang"
VALUES="$GOLANG_DIR/golang-values.mk"
LINK_DIR="$WRT_MAIN/package/feeds/packages"
UPSTREAM_REPO="immortalwrt/packages"
UPSTREAM_REF="master"

# 需要跟踪的 Go 组件（"仓库:是否接受 prerelease"），取值规则与 Packages.sh 保持一致。
# Xray 从 v26.4 起把所有 release 都标成 prerelease，所以必须接受，否则永远停在旧版；
# sing-box 只取正式版，避免把 alpha 引入生产固件。
TRACKED="XTLS/Xray-core:true SagerNet/sing-box:false"

[ -d "$GOLANG_DIR" ] || { echo "::error::未找到 $GOLANG_DIR —— 请先执行 ./scripts/feeds update -a && ./scripts/feeds install -a"; exit 1; }
[ -f "$VALUES" ] || { echo "::error::未找到 $VALUES"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "::error::缺少 jq，无法解析 GitHub API"; exit 1; }

# ---------------------------------------------------------------------------
# 版本比较（Packages.sh 已不再做 Go 兼容过滤，此实现现为本脚本独立使用）
# ---------------------------------------------------------------------------
norm_ver() {
	local v=$1 a b c
	case "$v" in
		[0-9]*.[0-9]*) ;;
		*) printf '%s' "$v"; return 0 ;;
	esac
	IFS=. read -r a b c <<<"$v"
	printf '%s.%s.%s' "${a:-0}" "${b:-0}" "${c:-0}"
}

version_le() {
	local n1 n2
	n1=$(norm_ver "$1")
	n2=$(norm_ver "$2")
	[ "$(printf '%s\n%s\n' "$n1" "$n2" | sort -V | head -n 1)" = "$n1" ]
}

version_lt() {
	local n1 n2
	n1=$(norm_ver "$1")
	n2=$(norm_ver "$2")
	[ "$n1" != "$n2" ] && version_le "$n1" "$n2"
}

# ---------------------------------------------------------------------------
# 上游查询
# ---------------------------------------------------------------------------
gh_curl() {
	# 注意 1：token 为空时绝不能发 "Authorization: Bearer " 头，
	#   GitHub 会判为 Bad credentials 返回 401，curl -f 直接失败 → 整条链路静默废掉。
	# 注意 2：--compressed 让 GitHub 返回 gzip，Xray 的 release 列表实测传输耗时 7s → 3s，
	#   同时显著降低「大响应被中途掐断 → JSON 截断」的风险（与 Packages.sh 同一处理）。
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl -sfL --compressed --max-time 60 \
			-H "Authorization: Bearer $GITHUB_TOKEN" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"$1"
	else
		curl -sfL --compressed --max-time 60 \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"$1"
	fi
}

gh_tags() {
	local repo=$1 allow_pre=$2 sel
	# 用两个明确的表达式代替 --argjson 布尔传参，避免 jq 版本差异带来的歧义
	if [ "$allow_pre" = "true" ]; then
		sel='map(select(.draft | not)) | .[].tag_name'
	else
		sel='map(select(.draft | not)) | map(select(.prerelease | not)) | .[].tag_name'
	fi
	gh_curl "https://api.github.com/repos/$repo/releases?per_page=30" 2>/dev/null \
		| jq -r "$sel" 2>/dev/null \
		| tr -d '\r' \
		|| true
}

# 取最新 tag，同时排除 rc / beta / alpha / dev 这类非稳定标记
pick_latest_tag() {
	local repo=$1 allow_pre=$2 t
	for t in $(gh_tags "$repo" "$allow_pre"); do
		case "$t" in
			*rc*|*RC*|*beta*|*alpha*|*dev*) continue ;;
		esac
		printf '%s' "$t"
		return 0
	done
	return 1
}

go_mod_requires() {
	local repo=$1 tag=$2
	curl -sfL --max-time 20 "https://raw.githubusercontent.com/$repo/$tag/go.mod" 2>/dev/null \
		| tr -d '\r' \
		| awk '/^go /{print $2; exit}' \
		|| true
}

# ---------------------------------------------------------------------------
# 1) 计算所有被跟踪组件里最高的 Go 要求
# ---------------------------------------------------------------------------
REQ_MM=""
REQ_DETAIL=""

for item in $TRACKED; do
	REPO="${item%:*}"
	PRE="${item##*:}"

	TAG=$(pick_latest_tag "$REPO" "$PRE" || true)
	if [ -z "$TAG" ]; then
		echo "::warning::无法获取 $REPO 的最新 release（API 限流或网络问题），跳过其 Go 版本检查"
		continue
	fi

	REQF=$(go_mod_requires "$REPO" "$TAG")
	if [ -z "$REQF" ]; then
		echo "::warning::$REPO@$TAG 的 go.mod 未声明 go 版本，跳过"
		continue
	fi

	MM=$(printf '%s' "$REQF" | cut -d. -f1,2)
	echo "  组件探测：$REPO $TAG → 要求 go $REQF"
	REQ_DETAIL="${REQ_DETAIL}${REPO}@${TAG}(go${REQF}) "

	if [ -z "$REQ_MM" ] || version_lt "$REQ_MM" "$MM"; then
		REQ_MM="$MM"
	fi
done

if [ -z "$REQ_MM" ]; then
	echo "::error::未能确定任何组件的 Go 版本要求（全部查询失败），中止以免误判为无需升级"
	exit 1
fi

# ---------------------------------------------------------------------------
# 2) 与当前工具链比对
# ---------------------------------------------------------------------------
CUR_MM=$(grep -m1 '^GO_DEFAULT_VERSION:=' "$VALUES" 2>/dev/null | cut -d= -f2 | tr -d ' \r' || true)
[ -n "$CUR_MM" ] || { echo "::error::无法从 $VALUES 读取 GO_DEFAULT_VERSION"; exit 1; }

# 真正的工具链补丁号在 golang$CUR_MM/Makefile 的 GO_VERSION_PATCH 里（如 1.26.8）
CUR_PATCH=$(grep -m1 '^GO_VERSION_PATCH:=' "$GOLANG_DIR/golang$CUR_MM/Makefile" 2>/dev/null | cut -d= -f2 | tr -d ' \r' || true)
CUR_FULL="$CUR_MM${CUR_PATCH:+.$CUR_PATCH}"

echo "::notice::组件需要的最高 Go 版本 = $REQ_MM（来源：$REQ_DETAIL）"
echo "::notice::当前源码线 Go 工具链 = $CUR_FULL"

if version_le "$REQ_MM" "$CUR_MM"; then
	echo "::notice::Go $CUR_FULL 已满足全部组件要求，无需升级"
	exit 0
fi

echo "::warning::需要升级 Go 工具链：$CUR_MM → $REQ_MM"

# ---------------------------------------------------------------------------
# 3) 准备 golang$REQ_MM 包
# ---------------------------------------------------------------------------
DEST="$GOLANG_DIR/golang$REQ_MM"

if [ -f "$DEST/Makefile" ]; then
	echo "   golang$REQ_MM 已存在于 feeds，跳过安装"
else
	SRC="$SCRIPT_DIR/golang$REQ_MM"
	if [ -f "$SRC/Makefile" ]; then
		echo "   从仓库自带副本安装：scripts/golang$REQ_MM/ → $DEST"
		cp -rf "$SRC" "$DEST"
	else
		echo "   仓库内无副本，尝试从 $UPSTREAM_REPO@$UPSTREAM_REF 拉取 golang$REQ_MM"
		mkdir -p "$DEST"
		for f in Makefile test.sh test-version.sh; do
			if ! curl -sfL --max-time 30 -o "$DEST/$f" \
				"https://raw.githubusercontent.com/$UPSTREAM_REPO/$UPSTREAM_REF/lang/golang/golang$REQ_MM/$f"; then
				echo "::error::上游 $UPSTREAM_REPO@$UPSTREAM_REF 不存在 golang$REQ_MM，无法满足 $REQ_DETAIL 的要求。"
				echo "::error::请手工引入该 Go 版本，或把组件版本降到 go 要求不超过 $CUR_MM 的版本。"
				rm -rf "$DEST"
				exit 1
			fi
		done
	fi
fi

[ -f "$DEST/Makefile" ] || { echo "::error::golang$REQ_MM 安装失败"; exit 1; }
NEW_HASH=$(grep -m1 '^PKG_HASH:=' "$DEST/Makefile" | cut -d= -f2 | tr -d ' \r')
echo "   golang$REQ_MM PKG_HASH=$NEW_HASH"

# ---------------------------------------------------------------------------
# 4) 注册到 package/feeds/packages/（新增包必须重新链接，否则构建系统扫不到）
# ---------------------------------------------------------------------------
if [ -d "$LINK_DIR" ]; then
	if [ ! -e "$LINK_DIR/golang$REQ_MM" ]; then
		# 首选软链（与 ./scripts/feeds install 的行为一致）；
		# 在部分环境（如 Windows 无特权账户）软链会失败，退化为目录复制。
		if ln -sf "../../../feeds/packages/lang/golang/golang$REQ_MM" "$LINK_DIR/golang$REQ_MM" 2>/dev/null; then
			echo "   已注册软链：$LINK_DIR/golang$REQ_MM"
		elif cp -rf "$DEST" "$LINK_DIR/golang$REQ_MM" 2>/dev/null; then
			echo "::warning::软链创建失败，已改用目录复制方式注册 golang$REQ_MM"
		else
			echo "::error::注册 golang$REQ_MM 到 $LINK_DIR 失败"
			exit 1
		fi
	else
		echo "   $LINK_DIR/golang$REQ_MM 已存在，跳过注册"
	fi
else
	echo "::warning::$LINK_DIR 不存在，跳过注册；若构建时报找不到 golang$REQ_MM，请确认 feeds install 已执行"
fi

# ---------------------------------------------------------------------------
# 5) 切换默认 Go 版本
# ---------------------------------------------------------------------------
cp -f "$VALUES" "$VALUES.bak"
sed -i "s|^GO_DEFAULT_VERSION:=.*|GO_DEFAULT_VERSION:=$REQ_MM|" "$VALUES"

NEW_MM=$(grep -m1 '^GO_DEFAULT_VERSION:=' "$VALUES" | cut -d= -f2 | tr -d ' \r')
if [ "$NEW_MM" != "$REQ_MM" ]; then
	echo "::error::切换 GO_DEFAULT_VERSION 失败（期望 $REQ_MM，实际 $NEW_MM）"
	mv -f "$VALUES.bak" "$VALUES"
	exit 1
fi
rm -f "$VALUES.bak"

echo "::notice::Go 工具链已切换：$CUR_MM → $NEW_MM（golang$REQ_MM）"
echo "::notice::所有使用 golang/host 的包（xray-core / sing-box / tailscale / v2ray-core ...）将以 Go $NEW_MM 编译"
