#!/usr/bin/env bash
# Konnect Data Plane bootstrap (certificate -> register -> fetch endpoints -> run DP container)
# Usage:
#   KONNECT_TOKEN=xxxx scripts/konnect-dp-bootstrap.sh \
#     --cp-name gm-sakaguchi-training \
#     --region us \
#     --image kong/kong-gateway:3.9 \
#     --labels "created-by:script,env:local" \
#     --container-name konnect-dp \
#     --ttl-seconds 0
#
# In CI (GitHub Actions) set secret KONNECT_TOKEN and call the script.
#
# Exit codes:
#   0 success
#   10 missing KONNECT_TOKEN
#   11 control plane not found
#   12 certificate registration failed
#   13 endpoints fetch failed
#   14 docker run failed
#
set -euo pipefail

# Defaults
CP_NAME="gm-sakaguchi-training"
REGION="us"
IMAGE="kong/kong-gateway:3.9"
LABELS="created-by:manual,type:docker-ci"
CONTAINER_NAME="konnect-dp-manual"
TTL_SECONDS=0   # >0 の場合、その秒後にコンテナと証明書を削除
CLEANUP_CERT=0  # 1 なら終了時に証明書削除
VERBOSE=0

log(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*" >&2; }
err(){ echo "[ERROR] $*" >&2; }
dbg(){ if [[ $VERBOSE -eq 1 ]]; then echo "[DBG] $*"; fi }

die(){ err "$2"; exit "$1"; }

usage(){ sed -n '1,60p' "$0" | grep -E '^#' | sed 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cp-name) CP_NAME="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --labels) LABELS="$2"; shift 2;;
    --container-name) CONTAINER_NAME="$2"; shift 2;;
    --ttl-seconds) TTL_SECONDS="$2"; shift 2;;
    --cleanup-cert) CLEANUP_CERT=1; shift;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

: "${KONNECT_TOKEN:?KONNECT_TOKEN environment variable required}" || die 10 "KONNECT_TOKEN not set"

KONNECT_API="https://${REGION}.api.konghq.com/v2"
WORKDIR=$(pwd)
CERT_DIR="certs"
CERT_KEY_PATH="${CERT_DIR}/tls.key"
CERT_PATH="${CERT_DIR}/tls.crt"
CERT_ID="" # filled after registration

mkdir -p "$CERT_DIR"

step_generate_certs(){
  if [[ -f $CERT_KEY_PATH && -f $CERT_PATH ]]; then
    log "Reusing existing certificate files in $CERT_DIR"
  else
    log "Generating new TLS key/cert (10 years)"
    openssl req -new -x509 -nodes -newkey rsa:2048 -subj "/CN=kongdp/C=US" -keyout "$CERT_KEY_PATH" -out "$CERT_PATH" -days 3650 >/dev/null 2>&1
  fi
  openssl x509 -noout -dates -in "$CERT_PATH" || true
}

step_get_cp_id(){
  log "Fetching Control Plane ID for name=$CP_NAME"
  local resp tmp_id
  resp=$(curl -sf -H "Authorization: Bearer $KONNECT_TOKEN" "${KONNECT_API}/control-planes?size=100") || true
  tmp_id=$(echo "$resp" | jq -r --arg name "$CP_NAME" '.data[] | select(.name==$name) | .id' | head -n1)
  if [[ -z "$tmp_id" || "$tmp_id" == "null" ]]; then
    die 11 "Control Plane '$CP_NAME' not found"
  fi
  CP_ID="$tmp_id"
  log "Control Plane ID: $CP_ID"
}

step_register_cert(){
  log "Registering Data Plane certificate"
  local cert_json cert_content create_resp pem_first_line
  # 誤り: 以前の実装は行ごとに "\\n" を埋め込み → API にはバックスラッシュ付き文字列が渡り validation error
  # 正: ファイルの生の改行を保持したまま JSON へ (jq が自動で \n エスケープし API 側で復元される)
  cert_content=$(tr -d '\r' < "$CERT_PATH")
  pem_first_line=$(printf '%s' "$cert_content" | head -n1)
  if [[ "$pem_first_line" != "-----BEGIN CERTIFICATE-----" ]]; then
    warn "Certificate file does not start with PEM header; first line: $pem_first_line"
  fi
  if grep -q '\\n' <<< "$cert_content"; then
    warn "Certificate content already contains literal \\n sequences (unexpected). Aborting to avoid invalid payload."
    die 12 "Certificate content malformed (contains literal \\n)"
  fi
  cert_json=$(jq -n --arg cert "$cert_content" '{cert:$cert}')
  create_resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$cert_json" \
    "${KONNECT_API}/control-planes/${CP_ID}/dp-client-certificates") || true
  dbg "Cert create response: $create_resp"
  # エラー詳細に pem-encoded-cert が含まれるかを検出し、ヒントを表示
  if echo "$create_resp" | grep -qi 'pem-encoded-cert'; then
    err "API reported PEM validation error. Check that the certificate is a single, valid PEM block without Windows CR or literal \\n."
  fi
  CERT_ID=$(echo "$create_resp" | jq -r '.id // empty')
  if [[ -z "$CERT_ID" ]]; then
    warn "Could not parse CERT_ID (maybe already exists?). Listing certificates to attempt reuse."
    CERT_ID=$(curl -sS -H "Authorization: Bearer $KONNECT_TOKEN" "${KONNECT_API}/control-planes/${CP_ID}/dp-client-certificates" | jq -r '.data[0].id // empty')
  fi
  [[ -n "$CERT_ID" ]] || die 12 "Certificate registration failed"
  log "Certificate ID: $CERT_ID"
}

step_fetch_endpoints(){
  log "Fetching CP & Telemetry endpoints"
  local cp_resp cp_ep tp_ep
  cp_resp=$(curl -sf -H "Authorization: Bearer $KONNECT_TOKEN" "${KONNECT_API}/control-planes/${CP_ID}") || true
  cp_ep=$(echo "$cp_resp" | jq -r '.config.control_plane_endpoint // empty')
  tp_ep=$(echo "$cp_resp" | jq -r '.config.telemetry_endpoint // empty')
  if [[ -z "$cp_ep" || -z "$tp_ep" ]]; then
    die 13 "Failed to obtain endpoints"
  fi
  CP_ENDPOINT=${cp_ep#https://}
  TP_ENDPOINT=${tp_ep#https://}
  log "CP_ENDPOINT=$CP_ENDPOINT"
  log "TP_ENDPOINT=$TP_ENDPOINT"
}

step_run_dp(){
  log "Starting Data Plane container: $CONTAINER_NAME"
  local CERT_RAW CERT_KEY_RAW
  CERT_RAW=$(cat "$CERT_PATH")
  CERT_KEY_RAW=$(cat "$CERT_KEY_PATH")
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  set +e
  docker run -d \
    --name "$CONTAINER_NAME" \
    -e "KONG_ROLE=data_plane" \
    -e "KONG_DATABASE=off" \
    -e "KONG_VITALS=off" \
    -e "KONG_CLUSTER_MTLS=pki" \
    -e "KONG_CLUSTER_CONTROL_PLANE=${CP_ENDPOINT}:443" \
    -e "KONG_CLUSTER_SERVER_NAME=${CP_ENDPOINT}" \
    -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${TP_ENDPOINT}:443" \
    -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${TP_ENDPOINT}" \
    -e "KONG_CLUSTER_CERT=${CERT_RAW}" \
    -e "KONG_CLUSTER_CERT_KEY=${CERT_KEY_RAW}" \
    -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
    -e "KONG_KONNECT_MODE=on" \
    -e "KONG_CLUSTER_DP_LABELS=${LABELS}" \
    -p 8000:8000 -p 8443:8443 \
    "$IMAGE" >/dev/null
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || die 14 "docker run failed"
  log "Container started. Tail (first 30s) logs:" 
  timeout 30s bash -c "docker logs -f $CONTAINER_NAME 2>&1 | sed -n '1,200p'" || true
}

cleanup(){
  if [[ $CLEANUP_CERT -eq 1 && -n $CERT_ID ]]; then
    log "Deleting certificate $CERT_ID"
    curl -sS -X DELETE -H "Authorization: Bearer $KONNECT_TOKEN" "${KONNECT_API}/control-planes/${CP_ID}/dp-client-certificates/${CERT_ID}" >/dev/null || true
  fi
  if [[ $TTL_SECONDS -gt 0 ]]; then
    log "TTL set: removing container $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

main(){
  step_generate_certs
  step_get_cp_id
  step_register_cert
  step_fetch_endpoints
  step_run_dp
  log "Done. Container: $CONTAINER_NAME (image $IMAGE)"
  if [[ $TTL_SECONDS -gt 0 ]]; then
    log "Sleeping $TTL_SECONDS seconds before auto cleanup..."
    sleep "$TTL_SECONDS"
  fi
}

main "$@"
