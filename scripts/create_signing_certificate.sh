#!/bin/zsh
# 生成大佐翻译官的自签名代码签名证书，上传到 GitHub Secrets，并在桌面留一份离线备份。
#
# 为什么要它：ad-hoc 签名下，系统把辅助功能 / 屏幕录制授权绑在 cdhash 上，
# 每次更新二进制都变，用户每次都得重新授权。用固定证书签名后，授权绑的是
# `identifier "achord.dazuofanyiguan" and certificate leaf = H"<证书 SHA-1>"`，跨版本不变。
#
# **只跑一次。证书投入使用后不要再换**：换证书 = 所有用户再重新授权一次。
# 私钥和密码只在本机生成、直接上传，不会打印到终端。
#
# 用法：
#   scripts/create_signing_certificate.sh             正式生成并上传
#   scripts/create_signing_certificate.sh --dry-run   只在临时目录里生成、校验，不上传、不留备份
set -euo pipefail

REPO="Achordchan/bagayalu-translate"
CERT_CN="Bagayalu Translate Self-Signed"
BUNDLE_ID="achord.dazuofanyiguan"
VALID_DAYS=7300
P12_SECRET="MACOS_SIGNING_CERT_P12_BASE64"
PASSWORD_SECRET="MACOS_SIGNING_CERT_PASSWORD"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "[ERROR] 不认识的参数：$1（只支持 --dry-run）" >&2; exit 2 ;;
esac

for tool in openssl security codesign base64; do
  command -v "$tool" >/dev/null || { echo "[ERROR] 找不到 $tool" >&2; exit 1; }
done

BACKUP_DIR="$HOME/Desktop/大佐翻译官签名证书备份-$(date +%Y%m%d)"

if (( ! DRY_RUN )); then
  command -v gh >/dev/null || { echo "[ERROR] 找不到 gh（GitHub CLI）" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "[ERROR] gh 未登录，先跑 gh auth login" >&2; exit 1; }

  # 读不出 Secrets 列表时不能当成「没有」——那样可能把正在用的证书覆盖掉。
  existing_secrets="$(gh secret list --repo "$REPO" --json name -q '.[].name')" || {
    echo "[ERROR] 读不到 $REPO 的 Secrets 列表，无法确认是否已有证书，已中止。" >&2
    exit 1
  }
  if print -r -- "$existing_secrets" | grep -qx -e "$P12_SECRET" -e "$PASSWORD_SECRET"; then
    echo "[ERROR] $REPO 已经有签名证书的 Secret（$P12_SECRET / $PASSWORD_SECRET）。" >&2
    echo "        换证书会让所有用户再重新授权一次，脚本不会覆盖。" >&2
    echo "        确实要换，先在 GitHub 仓库设置里手动删掉这两个 Secret 再跑。" >&2
    exit 1
  fi

  if [[ -e "$BACKUP_DIR" ]]; then
    echo "[ERROR] 备份目录已存在：$BACKUP_DIR" >&2
    echo "        今天可能已经跑过一次，先确认那份备份，再挪走它重跑。" >&2
    exit 1
  fi
fi

umask 077
WORK="$(mktemp -d)"
KEYCHAIN="$WORK/validate.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"

# 校验时要把临时钥匙串临时加进搜索列表（codesign 只在搜索列表里找身份），结束时原样恢复。
ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}")
SEARCH_LIST_CHANGED=0

cleanup() {
  set +e
  if (( SEARCH_LIST_CHANGED )); then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "[1/5] 生成证书（RSA 3072，有效期 $VALID_DAYS 天）"
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_CN
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
req_output="$(openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days "$VALID_DAYS" \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>&1)" || {
  print -r -- "$req_output" >&2
  echo "[ERROR] 生成证书失败" >&2
  exit 1
}

# 不带换行：这个文件原样上传成 Secret，CI 拿它解 p12，多一个换行就是错密码。
printf '%s' "$(openssl rand -hex 24)" > "$WORK/p12-password"
# macOS 的 security import 读不了 OpenSSL 3 默认的 p12 加密算法，要 -legacy；LibreSSL 本来就是旧算法。
legacy_flag=()
if openssl version | grep -q '^OpenSSL 3'; then
  legacy_flag=(-legacy)
fi
openssl pkcs12 -export "${legacy_flag[@]}" -name "$CERT_CN" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout "file:$WORK/p12-password" -out "$WORK/signing.p12"
rm -f "$WORK/key.pem"

SHA1="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
SHA256="$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//')"
NOT_AFTER="$(openssl x509 -in "$WORK/cert.pem" -noout -enddate | sed 's/.*=//')"
EXPECTED_DR="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SHA1\""

echo "[2/5] 用和 CI 相同的方式导入临时钥匙串并试签名"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/signing.p12" -k "$KEYCHAIN" -P "$(cat "$WORK/p12-password")" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
SEARCH_LIST_CHANGED=1

cp /usr/bin/true "$WORK/probe"
sign_output="$(codesign --force --sign "$CERT_CN" --identifier "$BUNDLE_ID" --timestamp=none "$WORK/probe" 2>&1)" || {
  print -r -- "$sign_output" >&2
  echo "[ERROR] 用新证书试签名失败，已中止，什么都没上传。" >&2
  exit 1
}
codesign --verify --strict "$WORK/probe"
actual_dr="$(codesign -d -r- "$WORK/probe" 2>&1 | sed -n 's/^.*designated => //p')"
if [[ "$actual_dr" != "$EXPECTED_DR" ]]; then
  echo "[ERROR] 签名后的身份要求和预期不一致，已中止，什么都没上传。" >&2
  echo "        预期：$EXPECTED_DR" >&2
  echo "        实际：$actual_dr" >&2
  exit 1
fi

security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
SEARCH_LIST_CHANGED=0
security delete-keychain "$KEYCHAIN"
echo "      身份要求：$EXPECTED_DR"

base64 -i "$WORK/signing.p12" | tr -d '\n' > "$WORK/signing.p12.base64"

if (( DRY_RUN )); then
  echo "[3/5] --dry-run：跳过备份"
  echo "[4/5] --dry-run：跳过上传"
  echo "[5/5] --dry-run 完成，临时文件已删除。SHA-1：$SHA1"
  exit 0
fi

echo "[3/5] 写离线备份：$BACKUP_DIR"
mkdir -m 700 "$BACKUP_DIR"
cp "$WORK/signing.p12" "$BACKUP_DIR/签名证书.p12"
cp "$WORK/p12-password" "$BACKUP_DIR/p12密码.txt"
cp "$WORK/cert.pem" "$BACKUP_DIR/证书公钥.pem"
cat > "$BACKUP_DIR/说明.txt" <<EOF
大佐翻译官 自签名代码签名证书

证书名称：$CERT_CN
SHA-1：   $SHA1
SHA-256： $SHA256
到期：    $NOT_AFTER
身份要求：$EXPECTED_DR

签名证书.p12 + p12密码.txt = 私钥。丢了，所有用户要重新授权一次；
泄露了，别人能签出继承用户授权的程序。请存进密码管理器或加密的离线介质，
确认存好后删掉桌面上这份。

GitHub Secrets（$REPO）：
  $P12_SECRET      = base64(签名证书.p12)
  $PASSWORD_SECRET = p12密码.txt 的内容

万一 Secrets 被误删，用这份备份重新上传，证书不变，用户不用重新授权：
  base64 -i 签名证书.p12 | tr -d '\\n' | gh secret set $P12_SECRET --repo $REPO
  gh secret set $PASSWORD_SECRET --repo $REPO < p12密码.txt
EOF

echo "[4/5] 上传到 GitHub Secrets（$REPO）"
gh secret set "$P12_SECRET" --repo "$REPO" < "$WORK/signing.p12.base64"
gh secret set "$PASSWORD_SECRET" --repo "$REPO" < "$WORK/p12-password"

uploaded="$(gh secret list --repo "$REPO" --json name -q '.[].name')"
for name in "$P12_SECRET" "$PASSWORD_SECRET"; do
  print -r -- "$uploaded" | grep -qx "$name" || {
    echo "[ERROR] 上传后没在 Secrets 列表里看到 $name，请到仓库设置里检查。备份在 $BACKUP_DIR" >&2
    exit 1
  }
done

echo "[5/5] 完成"
echo
echo "  证书 SHA-1：$SHA1"
echo "  到期：      $NOT_AFTER"
echo "  备份：      $BACKUP_DIR"
echo
echo "接下来："
echo "  1. 把备份文件夹存进密码管理器或加密的离线介质，确认后删掉桌面这份。"
echo "  2. 把上面的「证书 SHA-1」发给 Claude，写死到 CI 的签名校验里（这是公开信息，不是密钥）。"
