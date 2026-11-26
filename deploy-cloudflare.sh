#!/usr/bin/env bash
# ============================================================
# 存钱计划 · 一键部署到 Cloudflare Workers（免费额度即可）
#
# 用法（在项目目录下执行）：
#   CF_ACCOUNT_ID=你的账户ID CF_API_TOKEN=你的令牌 bash deploy-cloudflare.sh
# 可选：WORKER_NAME=cunqian-plan  SHARE_KEY=自定义访问码
#
# 令牌权限要求：模板「Edit Cloudflare Workers」（含 KV 读写）即可。
# 重复执行会更新同一个 Worker，链接不变。
# ============================================================
set -euo pipefail

: "${CF_ACCOUNT_ID:?缺少 CF_ACCOUNT_ID（Cloudflare 仪表盘右侧「账户 ID」）}"
: "${CF_API_TOKEN:?缺少 CF_API_TOKEN（用「Edit Cloudflare Workers」模板创建）}"

NAME="${WORKER_NAME:-cunqian-plan}"
if [ -z "${SHARE_KEY:-}" ]; then
  SHARE_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Z2-9' | head -c 12)
fi
API="https://api.cloudflare.com/client/v4"
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

call() { curl -s -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" "$@"; }
check() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d.get('success'):
    print(json.dumps(d.get('errors', d), ensure_ascii=False)); sys.exit(1)
print(json.dumps(d.get('result'), ensure_ascii=False))
"; }

echo "==> 1/4 创建 KV 存储命名空间…"
NSID=$(call -X POST "$API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces" \
  --data "{\"title\":\"$NAME-kv\"}" | check 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
if [ -z "$NSID" ]; then
  NSID=$(call "$API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces" | check | python3 -c "
import sys, json
for ns in json.load(sys.stdin):
    if ns['title'] == '$NAME-kv': print(ns['id']); break
")
fi
echo "    KV namespace: $NSID"

echo "==> 2/4 写入页面资产到 KV…"
call -sS -X PUT "$API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$NSID/values/asset:index" \
  -H "Content-Type: text/plain" --data-binary "@$DIR/index.html" | check >/dev/null
call -sS -X PUT "$API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$NSID/values/asset:manifest" \
  -H "Content-Type: text/plain" --data-binary "@$DIR/manifest.json" | check >/dev/null
echo "    页面资产已写入（asset:index / asset:manifest）"

echo "==> 3/4 上传 Worker（云同步后端）…"
cat > "$TMP/meta.json" <<JSON
{
  "main_module": "worker.js",
  "compatibility_date": "2024-11-01",
  "bindings": [
    {"type": "kv_namespace", "name": "KV", "namespace_id": "$NSID"},
    {"type": "plain_text", "name": "SHARE_KEY", "text": "$SHARE_KEY"}
  ]
}
JSON

curl -s -X PUT "$API/accounts/$CF_ACCOUNT_ID/workers/scripts/$NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -F "metadata=@$TMP/meta.json;type=application/json" \
  -F "worker.js=@$DIR/worker.js;type=application/javascript+module" > "$TMP/up.json"
python3 - "$TMP/up.json" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
if not d.get('success'):
    print('上传失败:', json.dumps(d.get('errors', d), ensure_ascii=False)); sys.exit(1)
print('    上传成功')
PY

echo "==> 4/4 开启公开访问域名（workers.dev）…"
call -X POST "$API/accounts/$CF_ACCOUNT_ID/workers/scripts/$NAME/subdomain" \
  --data '{"enabled":true,"previews_enabled":true}' > /dev/null || true
SUB=$(call "$API/accounts/$CF_ACCOUNT_ID/workers/subdomain" | check | python3 -c "import sys,json;print(json.load(sys.stdin)['subdomain'])")

echo "==> 5/5 验证部署…"
sleep 3
URL="https://$NAME.$SUB.workers.dev"
CODE=$(curl -s -o /tmp/cfcheck.json -w "%{http_code}" "$URL/?sharecode=$SHARE_KEY")
echo "    匿名访问状态码: $CODE"

echo
echo "=============================================="
echo "  部署完成"
echo "  分享链接（整条原样使用，勿删参数）："
echo "  $URL/?sharecode=$SHARE_KEY"
echo "=============================================="
if [ "$CODE" = "200" ]; then
  echo "  ✅ 匿名可访问：任何设备用这条链接都能打开"
else
  echo "  ⚠️ 状态码非 200：等几秒再试，或检查返回内容 /tmp/cfcheck.json"
fi
