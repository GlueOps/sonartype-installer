#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo -e "\n==> $*\n"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

require_env(){ [[ -n "${!1:-}" ]] || die "Missing env var: $1"; }

# -------- Required --------
require_env BASE_DOMAIN                 # e.g. repo.us-east.example.com  (regional/mirror hostname)
require_env ACME_EMAIL                  # ACME email
require_env NEXUS_NEW_ADMIN_PASSWORD

# -------- Optional (global latency hostname) --------
# A second, region-independent hostname (e.g. repo.example.com) served by every
# mirror behind a geo/latency DNS record. Its TLS cert is NOT obtained by Caddy:
# the same wildcard is issued once elsewhere and copied to every host, because a
# name that resolves to a different server each time cannot pass HTTP-01.
GLOBAL_BASE_DOMAIN="${GLOBAL_BASE_DOMAIN:-}"   # e.g. repo.example.com (optional)

# Basename of the pre-issued cert pair in ${STACK_DIR}/certs, without extension.
# Defaults to the global hostname, so repo.example.com -> certs/repo.example.com.{crt,key}.
GLOBAL_CERT_NAME="${GLOBAL_CERT_NAME:-${GLOBAL_BASE_DOMAIN}}"

# -------- TLS / DNS-01 (Route53) for REGIONAL hostnames only --------
# You do NOT need this for GLOBAL if you're deploying a shared wildcard cert to ${STACK_DIR}/certs.
# Keep ENABLE_DNS_CHALLENGE=true only if you want DNS-01 for the regional names too.
ENABLE_DNS_CHALLENGE="${ENABLE_DNS_CHALLENGE:-false}"
AWS_REGION="${AWS_REGION:-us-east-1}"  # Route53 is global, but AWS SDK often wants a region

# Accept either AWS_* or short names
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${ACCESS_KEY_ID:-}}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${SECRET_ACCESS_KEY:-}}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-${SESSION_TOKEN:-}}"

# -------- Optional --------
NEXUS_IMAGE="${NEXUS_IMAGE:-sonatype/nexus3:3.94.1}"
STACK_DIR="${STACK_DIR:-/opt/nexus-stack}"
NEXUS_DATA_DIR="${NEXUS_DATA_DIR:-/opt/nexus/nexus-data}"

# Ports (internal to Nexus container). Caddy exposes 80/443 only.
P_DOCKERHUB="${P_DOCKERHUB:-5000}"
P_GHCR="${P_GHCR:-5001}"
P_QUAY="${P_QUAY:-5002}"
P_ECR="${P_ECR:-5003}"
P_K8S="${P_K8S:-5004}"
P_GAR="${P_GAR:-5005}"
P_GCR="${P_GCR:-5006}"

ENABLE_ANON="${ENABLE_ANON:-true}"

# ---- S3 Blob Store (optional) ----
# If S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY are set, script creates blobstore "s3"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
S3_SECRET_KEY="${S3_SECRET_KEY:-}"
S3_PREFIX="${S3_PREFIX:-nexus/}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-true}"  # "true" / "false"

# Optional prewarm
PREWARM="${PREWARM:-false}"
PREWARM_IMAGES_FILE="${PREWARM_IMAGES_FILE:-}"

# -------- Derived hostnames (regional) --------
UI_HOST="${BASE_DOMAIN}"
DOCKERHUB_HOST="dockerhub.${BASE_DOMAIN}"
GHCR_HOST="ghcr.${BASE_DOMAIN}"
QUAY_HOST="quay.${BASE_DOMAIN}"
ECR_HOST="ecr.${BASE_DOMAIN}"
K8S_HOST="k8s.${BASE_DOMAIN}"
GAR_HOST="gcp.${BASE_DOMAIN}"
GCR_HOST="gcr.${BASE_DOMAIN}"

# -------- Derived hostnames (global latency; optional) --------
GLOBAL_UI_HOST=""
GLOBAL_DOCKERHUB_HOST=""
GLOBAL_GHCR_HOST=""
GLOBAL_QUAY_HOST=""
GLOBAL_ECR_HOST=""
GLOBAL_K8S_HOST=""
GLOBAL_GAR_HOST=""
GLOBAL_GCR_HOST=""
if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
  GLOBAL_UI_HOST="${GLOBAL_BASE_DOMAIN}"
  GLOBAL_DOCKERHUB_HOST="dockerhub.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_GHCR_HOST="ghcr.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_QUAY_HOST="quay.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_ECR_HOST="ecr.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_K8S_HOST="k8s.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_GAR_HOST="gcp.${GLOBAL_BASE_DOMAIN}"
  GLOBAL_GCR_HOST="gcr.${GLOBAL_BASE_DOMAIN}"
fi

# Helper: join regional + global hostnames for one site label (safe with set -u)
site_hosts() {
  local regional="${1:-}"
  local global="${2:-}"
  if [[ -n "${regional}" && -n "${global}" ]]; then
    echo "${regional}, ${global}"
  elif [[ -n "${regional}" ]]; then
    echo "${regional}"
  elif [[ -n "${global}" ]]; then
    echo "${global}"
  else
    return 1
  fi
}

# Decide blob store name
BLOBSTORE_NAME="default"
if [[ -n "${S3_ENDPOINT}" && -n "${S3_BUCKET}" && -n "${S3_ACCESS_KEY}" && -n "${S3_SECRET_KEY}" ]]; then
  BLOBSTORE_NAME="s3"
fi

# -------- Validate DNS-01 env (if enabled) --------
if [[ "${ENABLE_DNS_CHALLENGE}" == "true" ]]; then
  [[ -n "${AWS_ACCESS_KEY_ID}" ]] || die "ENABLE_DNS_CHALLENGE=true requires AWS_ACCESS_KEY_ID (or ACCESS_KEY_ID)"
  [[ -n "${AWS_SECRET_ACCESS_KEY}" ]] || die "ENABLE_DNS_CHALLENGE=true requires AWS_SECRET_ACCESS_KEY (or SECRET_ACCESS_KEY)"
fi

# -------- Setup dirs/perms (fixes restart loops) --------
log "Preparing directories"
mkdir -p "${STACK_DIR}" "${NEXUS_DATA_DIR}"
mkdir -p "${NEXUS_DATA_DIR}/log/audit" "${NEXUS_DATA_DIR}/etc"
mkdir -p "${STACK_DIR}/certs"
chown -R 200:200 "${NEXUS_DATA_DIR}" || true
chmod -R u+rwX,g+rwX "${NEXUS_DATA_DIR}" || true

# If GLOBAL enabled, warn if certs not present (Caddy will fail those sites until present)
if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
  if [[ ! -f "${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.crt" || ! -f "${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.key" ]]; then
    log "WARNING: Global hostname enabled but cert files are missing:"
    echo "  Expected: ${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.crt"
    echo "            ${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.key"
    echo "  Global TLS sites will fail to serve until these are deployed (e.g. from CI)."
  fi
fi

# S3-compat property (safe even if you don't end up using S3)
NEXUS_PROPS="${NEXUS_DATA_DIR}/etc/nexus.properties"
touch "${NEXUS_PROPS}"
if ! grep -q '^nexus\.blobstore\.s3\.ownership\.check\.disabled=' "${NEXUS_PROPS}" 2>/dev/null; then
  echo "nexus.blobstore.s3.ownership.check.disabled=true" >> "${NEXUS_PROPS}"
fi
chown 200:200 "${NEXUS_PROPS}" || true
chmod 600 "${NEXUS_PROPS}" || true

# -------- Write Caddy Dockerfile (only if DNS-01 enabled for regional) --------
if [[ "${ENABLE_DNS_CHALLENGE}" == "true" ]]; then
  log "Writing Dockerfile.caddy (Caddy + Route53 DNS module)"
  cat > "${STACK_DIR}/Dockerfile.caddy" <<'EOF'
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/route53

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF
fi

# -------- Calculate JVM memory (80% of system RAM) --------
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
JVM_MEM_GB=$((TOTAL_MEM_GB * 80 / 100))

# Ensure minimum of 1GB
if [[ ${JVM_MEM_GB} -lt 1 ]]; then
  JVM_MEM_GB=1
fi

log "Total system memory: ${TOTAL_MEM_GB}GB, allocating ${JVM_MEM_GB}GB (80%) to JVM"

# -------- Write compose --------
log "Writing docker-compose.yml"
cat > "${STACK_DIR}/docker-compose.yml" <<EOF
services:
  nexus:
    image: ${NEXUS_IMAGE}
    container_name: nexus
    restart: unless-stopped
    environment:
      - INSTALL4J_ADD_VM_PARAMS="-Dnexus.http.client.max.total=400 -Dnexus.http.client.max.per.route=60 -Xms${JVM_MEM_GB}g -Xmx${JVM_MEM_GB}g -XX:MaxDirectMemorySize=${JVM_MEM_GB}g -Djava.util.prefs.userRoot=/nexus-data/javaprefs"
    volumes:
      - ${NEXUS_DATA_DIR}:/nexus-data
    ports:
      - "127.0.0.1:8081:8081"
      - "127.0.0.1:5000:5000"
      - "127.0.0.1:5001:5001"
      - "127.0.0.1:5002:5002"
      - "127.0.0.1:5003:5003"
      - "127.0.0.1:5004:5004"
      - "127.0.0.1:5005:5005"
      - "127.0.0.1:5006:5006"
    expose:
      - "8081"
      - "${P_DOCKERHUB}"
      - "${P_GHCR}"
      - "${P_QUAY}"
      - "${P_ECR}"
      - "${P_K8S}"
      - "${P_GAR}"
      - "${P_GCR}"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536

  caddy:
EOF

if [[ "${ENABLE_DNS_CHALLENGE}" == "true" ]]; then
  cat >> "${STACK_DIR}/docker-compose.yml" <<EOF
    build:
      context: .
      dockerfile: Dockerfile.caddy
EOF
else
  cat >> "${STACK_DIR}/docker-compose.yml" <<EOF
    image: caddy:2
EOF
fi

cat >> "${STACK_DIR}/docker-compose.yml" <<EOF
    container_name: nexus-caddy
    restart: unless-stopped
    depends_on:
      - nexus
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${STACK_DIR}/Caddyfile:/etc/caddy/Caddyfile
      - ${STACK_DIR}/caddy-data:/data
      - ${STACK_DIR}/caddy-config:/config
      - ${STACK_DIR}/certs:/certs:ro
EOF

if [[ "${ENABLE_DNS_CHALLENGE}" == "true" ]]; then
  cat >> "${STACK_DIR}/docker-compose.yml" <<EOF
    environment:
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
      - AWS_REGION=${AWS_REGION}
      - AWS_DEFAULT_REGION=${AWS_REGION}
EOF
  if [[ -n "${AWS_SESSION_TOKEN}" ]]; then
    cat >> "${STACK_DIR}/docker-compose.yml" <<EOF
      - AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
EOF
  fi
fi

# -------- Write Caddyfile --------
log "Writing Caddyfile"
{
  echo "{"
  echo "  email ${ACME_EMAIL}"
  if [[ "${ENABLE_DNS_CHALLENGE}" == "true" ]]; then
    echo "  acme_dns route53"
  fi
  echo "}"
  echo

  echo "(registry_proxy) {"
  echo "  reverse_proxy {args.0} {"
  echo "    header_up Host {host}"
  echo "    header_up X-Forwarded-Proto {scheme}"
  echo "    header_up X-Forwarded-Host {host}"
  echo "    header_up X-Forwarded-Port {server_port}"
  echo
  echo "    flush_interval -1"
  echo
  echo "    transport http {"
  echo "      versions 1.1"
  echo "      dial_timeout 300s"
  echo "      response_header_timeout 300s"
  echo "      read_timeout 0"
  echo "      write_timeout 0"
  echo "      request_buffer 0"
  echo "    }"
  echo "  }"
  echo "}"
  echo
  # Regional (ACME default = HTTP-01, or DNS-01 if ENABLE_DNS_CHALLENGE=true)
  cat <<EOF
$(site_hosts "${UI_HOST}" "") {
  reverse_proxy nexus:8081
  log {
    output file /data/logs/nexus-access.log
    format console
  }
}

$(site_hosts "${DOCKERHUB_HOST}" "") {
  reverse_proxy nexus:${P_DOCKERHUB}
  log {
    output file /data/logs/dockerhub-access.log
    format console
  }
}
$(site_hosts "${GHCR_HOST}" "") {
  reverse_proxy nexus:${P_GHCR}
  log {
    output file /data/logs/ghcr-access.log
    format console
  }
}
$(site_hosts "${QUAY_HOST}" "") {
  reverse_proxy nexus:${P_QUAY}
  log {
    output file /data/logs/quay-access.log
    format console
  }
}
$(site_hosts "${ECR_HOST}" "") {
  reverse_proxy nexus:${P_ECR}
  log {
    output file /data/logs/ecr-access.log
    format console
  }
}
$(site_hosts "${K8S_HOST}" "") {
  reverse_proxy nexus:${P_K8S}
  log {
    output file /data/logs/k8s-access.log
    format console
  }
}
$(site_hosts "${GAR_HOST}" "") {
  reverse_proxy nexus:${P_GAR}
  log {
    output file /data/logs/gar-access.log
    format console
  }
}
$(site_hosts "${GCR_HOST}" "") {
  reverse_proxy nexus:${P_GCR}
  log {
    output file /data/logs/gcr-access.log
    format console
  }
}
EOF

  # Global (static wildcard cert deployed to ${STACK_DIR}/certs/)
  if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
    cat <<EOF

$(site_hosts "" "${GLOBAL_UI_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:8081
}

$(site_hosts "" "${GLOBAL_DOCKERHUB_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_DOCKERHUB}
}
$(site_hosts "" "${GLOBAL_GHCR_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_GHCR}
}
$(site_hosts "" "${GLOBAL_QUAY_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_QUAY}
}
$(site_hosts "" "${GLOBAL_ECR_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_ECR}
}
$(site_hosts "" "${GLOBAL_K8S_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_K8S}
}
$(site_hosts "" "${GLOBAL_GAR_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_GAR}
}
$(site_hosts "" "${GLOBAL_GCR_HOST}") {
  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key
  reverse_proxy nexus:${P_GCR}
}
EOF
  fi

} > "${STACK_DIR}/Caddyfile"

# -------- Start stack --------
log "Starting Nexus + Caddy"
(cd "${STACK_DIR}" && docker compose up -d)

# -------- Wait for Nexus writable --------
log "Waiting for Nexus REST API..."
for _ in {1..300}; do
  if curl -fsS "http://127.0.0.1:8081/service/rest/v1/status/writable" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "http://127.0.0.1:8081/service/rest/v1/status/writable" >/dev/null 2>&1 || {
  docker logs --tail 200 nexus || true
  die "Nexus did not become writable"
}
log "Nexus is up."

# -------- Determine current admin password (rerun-safe) --------
# /security/users/{userId} only implements PUT and DELETE; listing is a query
# param on the collection. A GET on the item path returns 405 for every caller,
# so this must probe the collection or it can never succeed.
try_auth() {
  local pw="$1"
  local code
  code="$(curl -sS -u "admin:${pw}" -o /dev/null -w "%{http_code}" \
    "http://127.0.0.1:8081/service/rest/v1/security/users?userId=admin" || true)"
  [[ "$code" == "200" ]]
}

NX_ADMIN_PWD=""
if try_auth "${NEXUS_NEW_ADMIN_PASSWORD}"; then
  NX_ADMIN_PWD="${NEXUS_NEW_ADMIN_PASSWORD}"
else
  if [[ -f "${NEXUS_DATA_DIR}/admin.password" ]]; then
    NX_ADMIN_PWD="$(tr -d '\r\n' < "${NEXUS_DATA_DIR}/admin.password")"
  elif docker exec nexus sh -lc 'test -f /nexus-data/admin.password' >/dev/null 2>&1; then
    NX_ADMIN_PWD="$(docker exec nexus sh -lc 'cat /nexus-data/admin.password' | tr -d '\r\n')"
  else
    die "Couldn't find admin.password and desired password isn't valid (rerun?)"
  fi
fi

# -------- Helper: call Nexus API (keeps status separate) --------
nexus_api() {
  local method="$1" path="$2" ctype="${3:-}" data="${4:-}"
  local url="http://127.0.0.1:8081${path}"
  local body; body="$(mktemp)"
  local code
  if [[ -n "$data" ]]; then
    code="$(curl -sS -u "admin:${NX_ADMIN_PWD}" -o "$body" -w "%{http_code}" \
      -H "Accept: application/json" -H "Content-Type: ${ctype}" \
      -X "$method" --data-binary "$data" "$url" || true)"
  else
    code="$(curl -sS -u "admin:${NX_ADMIN_PWD}" -o "$body" -w "%{http_code}" \
      -H "Accept: application/json" -X "$method" "$url" || true)"
  fi
  echo "$code"
  cat "$body" || true
  rm -f "$body"
}

# -------- Set admin password to desired --------
if [[ "${NX_ADMIN_PWD}" != "${NEXUS_NEW_ADMIN_PASSWORD}" ]]; then
  log "Setting admin password"
  out="$(nexus_api PUT "/service/rest/v1/security/users/admin/change-password" "text/plain" "${NEXUS_NEW_ADMIN_PASSWORD}")"
  code="$(head -n1 <<<"$out")"
  [[ "$code" == "204" || "$code" == "200" ]] || die "Password change failed (HTTP $code): $(tail -n +2 <<<"$out")"
  NX_ADMIN_PWD="${NEXUS_NEW_ADMIN_PASSWORD}"
fi

# -------- Enable anonymous (optional) --------
if [[ "${ENABLE_ANON}" == "true" ]]; then
  log "Enabling anonymous access"
  out="$(nexus_api PUT "/service/rest/v1/security/anonymous" "application/json" \
    '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}')"
  code="$(head -n1 <<<"$out")"
  [[ "$code" == "204" || "$code" == "200" ]] || die "Cannot set anonymous (HTTP $code): $(tail -n +2 <<<"$out")"
fi

# -------- Create S3 blob store (optional) --------
if [[ "${BLOBSTORE_NAME}" == "s3" ]]; then
  log "Ensuring S3 blob store exists (name: s3)"
  payload="$(python3 - <<PY
import json,os
print(json.dumps({
  "name":"s3",
  "bucketConfiguration":{
    "bucket":{
      "region": os.environ.get("S3_REGION","us-east-1"),
      "name": os.environ["S3_BUCKET"],
      "prefix": os.environ.get("S3_PREFIX","nexus/"),
      "expiration":"-1"
    },
    "failoverBuckets":[],
    "activeRegion": os.environ.get("S3_REGION","us-east-1"),
    "bucketSecurity":{
      "accessKeyId": os.environ["S3_ACCESS_KEY"],
      "secretAccessKey": os.environ["S3_SECRET_KEY"]
    },
    "advancedBucketConnection":{
      "endpoint": os.environ["S3_ENDPOINT"],
      "forcePathStyle": (os.environ.get("S3_FORCE_PATH_STYLE","true").lower()=="true")
    }
  }
}))
PY
)"
  out="$(nexus_api POST "/service/rest/v1/blobstores/s3" "application/json" "$payload")"
  code="$(head -n1 <<<"$out")"
  body="$(tail -n +2 <<<"$out")"
  if [[ "$code" != "201" && "$code" != "200" ]]; then
    if echo "$body" | grep -qiE 'already exists|duplicate'; then
      :
    else
      die "Failed to create S3 blob store (HTTP $code): $body"
    fi
  fi
fi

# -------- Create repos (idempotent-ish: ignore duplicates) --------
repo_exists() {
  local name="$1"
  curl -fsS -u "admin:${NX_ADMIN_PWD}" \
    "http://127.0.0.1:8081/service/rest/v1/repositories/${name}" >/dev/null 2>&1
}

mk_docker_proxy_payload() {
  local name="$1" remote="$2" port="$3" indexType="$4" indexUrl="$5"
  if [[ -n "${indexUrl}" ]]; then
    cat <<JSON
{"name":"${name}","online":true,
 "storage":{"blobStoreName":"${BLOBSTORE_NAME}","strictContentTypeValidation":true},
 "docker":{"v1Enabled":false,"forceBasicAuth":false,"httpPort":${port}},
 "dockerProxy":{"indexType":"${indexType}","indexUrl":"${indexUrl}"},
 "proxy":{"remoteUrl":"${remote}","contentMaxAge":64800,"metadataMaxAge":30},
 "negativeCache":{"enabled":false,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true,"authentication":null}}
JSON
  else
    cat <<JSON
{"name":"${name}","online":true,
 "storage":{"blobStoreName":"${BLOBSTORE_NAME}","strictContentTypeValidation":true},
 "docker":{"v1Enabled":false,"forceBasicAuth":false,"httpPort":${port}},
 "dockerProxy":{"indexType":"${indexType}"},
 "proxy":{"remoteUrl":"${remote}","contentMaxAge":64800,"metadataMaxAge":30},
 "negativeCache":{"enabled":false,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true,"authentication":null}}
JSON
  fi
}

mk_dockerhub_payload() {
  local port="$1"
  cat <<JSON
{"name":"dockerhub","online":true,
 "storage":{"blobStoreName":"${BLOBSTORE_NAME}","strictContentTypeValidation":true},
 "docker":{"v1Enabled":true,"forceBasicAuth":false,"httpPort":${port}},
 "dockerProxy":{"indexType":"HUB","indexUrl":"https://index.docker.io/"},
 "proxy":{"remoteUrl":"https://registry-1.docker.io","contentMaxAge":64800,"metadataMaxAge":30},
 "negativeCache":{"enabled":false,"timeToLive":1440},
 "httpClient":{"blocked":false,"autoBlock":true,"authentication":null}}
JSON
}

create_if_missing() {
  local name="$1" endpoint="$2" payload="$3"
  if repo_exists "$name"; then
    log "Repo exists: $name"
    return 0
  fi
  out="$(nexus_api POST "$endpoint" "application/json" "$payload")"
  code="$(head -n1 <<<"$out")"
  body="$(tail -n +2 <<<"$out")"
  if [[ "$code" =~ ^(200|201|204)$ ]]; then return 0; fi
  if [[ "$code" == "400" ]] && echo "$body" | grep -qiE 'already exists|duplicate'; then return 0; fi
  die "Failed creating $name (HTTP $code): $body"
}

log "Creating Docker proxy repos (blobStoreName=${BLOBSTORE_NAME})"
create_if_missing "dockerhub" "/service/rest/v1/repositories/docker/proxy" "$(mk_dockerhub_payload "${P_DOCKERHUB}")"
create_if_missing "ghcr" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "ghcr" "https://ghcr.io" "${P_GHCR}" "REGISTRY" "https://ghcr.io")"
create_if_missing "quay" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "quay" "https://quay.io" "${P_QUAY}" "REGISTRY" "https://quay.io")"
create_if_missing "public-ecr" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "public-ecr" "https://public.ecr.aws" "${P_ECR}" "REGISTRY" "https://public.ecr.aws")"
create_if_missing "registry-k8s-io" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "registry-k8s-io" "https://registry.k8s.io" "${P_K8S}" "REGISTRY" "https://registry.k8s.io")"
create_if_missing "us-docker-pkg-dev" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "us-docker-pkg-dev" "https://us-docker.pkg.dev" "${P_GAR}" "REGISTRY" "https://us-docker.pkg.dev")"
create_if_missing "gcr-io" "/service/rest/v1/repositories/docker/proxy" "$(mk_docker_proxy_payload "gcr-io" "https://gcr.io" "${P_GCR}" "REGISTRY" "https://gcr.io")"

log "Creating APT proxy repos (blobStoreName=${BLOBSTORE_NAME})"
create_if_missing "ubuntu-jammy" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-jammy\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"jammy\",\"flat\":false}}"
create_if_missing "ubuntu-jammy-updates" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-jammy-updates\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"jammy-updates\",\"flat\":false}}"
create_if_missing "ubuntu-jammy-security" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-jammy-security\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://security.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"jammy-security\",\"flat\":false}}"

create_if_missing "ubuntu-noble" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-noble\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"noble\",\"flat\":false}}"
create_if_missing "ubuntu-noble-updates" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-noble-updates\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"noble-updates\",\"flat\":false}}"
create_if_missing "ubuntu-noble-security" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-noble-security\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://security.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"noble-security\",\"flat\":false}}"

create_if_missing "ubuntu-resolute" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-resolute\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"resolute\",\"flat\":false}}"
create_if_missing "ubuntu-resolute-updates" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-resolute-updates\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://archive.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"resolute-updates\",\"flat\":false}}"
create_if_missing "ubuntu-resolute-security" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"ubuntu-resolute-security\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"http://security.ubuntu.com/ubuntu/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"resolute-security\",\"flat\":false}}"

create_if_missing "debian-bookworm" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-bookworm\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://deb.debian.org/debian/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"bookworm\",\"flat\":false}}"
create_if_missing "debian-bookworm-updates" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-bookworm-updates\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://deb.debian.org/debian/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"bookworm-updates\",\"flat\":false}}"
create_if_missing "debian-bookworm-security" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-bookworm-security\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://security.debian.org/debian-security\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"bookworm-security\",\"flat\":false}}"

create_if_missing "debian-trixie" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-trixie\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://deb.debian.org/debian/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"trixie\",\"flat\":false}}"
create_if_missing "debian-trixie-updates" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-trixie-updates\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://deb.debian.org/debian/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"trixie-updates\",\"flat\":false}}"
create_if_missing "debian-trixie-security" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"debian-trixie-security\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://security.debian.org/debian-security\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"trixie-security\",\"flat\":false}}"

create_if_missing "kubernetes-v1-32" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-32\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.32/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"
create_if_missing "kubernetes-v1-33" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-33\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.33/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"
create_if_missing "kubernetes-v1-34" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-34\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.34/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"
create_if_missing "kubernetes-v1-35" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-35\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.35/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"
create_if_missing "kubernetes-v1-36" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-36\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.36/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"
create_if_missing "kubernetes-v1-37" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"kubernetes-v1-37\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/core:/stable:/v1.37/deb/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"/\",\"flat\":true}}"

create_if_missing "helm-apt" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"helm-apt\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://packages.buildkite.com/helm-linux/helm-debian/any/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"any\",\"flat\":false}}"

# docker-ce, docker-ce-cli, containerd.io and the buildx/compose plugins come from Docker's
# own suite, not from the distro. One repository per suite, because a Nexus apt proxy pins a
# single distribution -- same shape as the ubuntu-* and debian-* proxies above. The path
# segment differs too: Docker publishes linux/ubuntu and linux/debian as separate trees.
create_if_missing "docker-ubuntu-jammy" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"docker-ubuntu-jammy\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/linux/ubuntu\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"jammy\",\"flat\":false}}"
create_if_missing "docker-ubuntu-noble" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"docker-ubuntu-noble\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/linux/ubuntu\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"noble\",\"flat\":false}}"
create_if_missing "docker-ubuntu-resolute" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"docker-ubuntu-resolute\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/linux/ubuntu\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"resolute\",\"flat\":false}}"
create_if_missing "docker-debian-bookworm" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"docker-debian-bookworm\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/linux/debian\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"bookworm\",\"flat\":false}}"
create_if_missing "docker-debian-trixie" "/service/rest/v1/repositories/apt/proxy" \
  "{\"name\":\"docker-debian-trixie\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/linux/debian\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"apt\":{\"distribution\":\"trixie\",\"flat\":false}}"

log "Creating Helm chart proxies + raw binaries proxies (blobStoreName=${BLOBSTORE_NAME})"
create_if_missing "helm-stable" "/service/rest/v1/repositories/helm/proxy" \
  "{\"name\":\"helm-stable\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://charts.helm.sh/stable\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true}}"

# The chart repositories a cluster build actually resolves against. helm-stable above is the
# archived charts.helm.sh/stable, frozen since 2020 and kept only because removing the line
# would orphan the repository on hosts that already have it -- this script never deletes.
create_if_missing "helm-tigera" "/service/rest/v1/repositories/helm/proxy" \
  "{\"name\":\"helm-tigera\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://docs.tigera.io/calico/charts\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true}}"
create_if_missing "helm-metrics-server" "/service/rest/v1/repositories/helm/proxy" \
  "{\"name\":\"helm-metrics-server\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://kubernetes-sigs.github.io/metrics-server\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true}}"
create_if_missing "helm-containeroo" "/service/rest/v1/repositories/helm/proxy" \
  "{\"name\":\"helm-containeroo\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":true},\"proxy\":{\"remoteUrl\":\"https://charts.containeroo.ch\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true}}"

create_if_missing "raw-k8s" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-k8s\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://dl.k8s.io/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"

create_if_missing "raw-helm" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-helm\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://get.helm.sh/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"

# Signing keys, which every node fetches before it can add the suite the key signs. Proxied
# at the host root rather than at the key itself so one repository covers both Docker trees:
#   <mirror>/repository/raw-docker/linux/ubuntu/gpg
#   <mirror>/repository/raw-buildkite-helm/gpgkey
create_if_missing "raw-docker" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-docker\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://download.docker.com/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"
create_if_missing "raw-buildkite-helm" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-buildkite-helm\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://packages.buildkite.com/helm-linux/helm-debian/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"

# pkgs.k8s.io serves Release.key next to the suite, but Release.key is not a file an apt
# proxy knows to fetch -- it recognises Release, InRelease, Release.gpg, Packages and pool/,
# and nothing else. So the key needs a raw proxy even though the debs it signs do not. This
# is pkgs.k8s.io; raw-k8s above is dl.k8s.io, a different host serving the binaries.
create_if_missing "raw-pkgs-k8s" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-pkgs-k8s\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://pkgs.k8s.io/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"

# Release assets (k9s and friends). A release download answers 302 to
# objects.githubusercontent.com, which Nexus follows -- so egress from this host reaches a
# CDN name that is not github.com. Allowlist both, or the fetch fails after the redirect.
create_if_missing "raw-github" "/service/rest/v1/repositories/raw/proxy" \
  "{\"name\":\"raw-github\",\"online\":true,\"storage\":{\"blobStoreName\":\"${BLOBSTORE_NAME}\",\"strictContentTypeValidation\":false,\"writePolicy\":\"ALLOW\"},\"proxy\":{\"remoteUrl\":\"https://github.com/\",\"contentMaxAge\":-1,\"metadataMaxAge\":1440},\"negativeCache\":{\"enabled\":false,\"timeToLive\":1440},\"httpClient\":{\"blocked\":false,\"autoBlock\":true},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"

# -------- Prewarm (optional) --------
if [[ "${PREWARM}" == "true" && -n "${PREWARM_IMAGES_FILE}" && -f "${PREWARM_IMAGES_FILE}" ]]; then
  log "Prewarming Docker caches by pulling manifests via TLS endpoints"
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    reg="${img%%/*}"
    rest="${img#*/}"
    case "$reg" in
      docker.io) host="${DOCKERHUB_HOST}" ;;
      ghcr.io) host="${GHCR_HOST}" ;;
      quay.io) host="${QUAY_HOST}" ;;
      public.ecr.aws) host="${ECR_HOST}" ;;
      registry.k8s.io) host="${K8S_HOST}" ;;
      us-docker.pkg.dev) host="${GAR_HOST}" ;;
      gcr.io) host="${GCR_HOST}" ;;
      *) echo "skip $img (unknown registry)"; continue ;;
    esac
    echo " - ${img} (via ${host})"
    curl -fsSL -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
      "https://${host}/v2/${rest%%[:@]*}/manifests/${rest##*:}" >/dev/null || true
  done < "${PREWARM_IMAGES_FILE}"
fi

cat <<EOF

✅ Stack is up.

Regional Nexus UI:
  https://${UI_HOST}
EOF

if [[ -n "${GLOBAL_UI_HOST}" ]]; then
  cat <<EOF
Global Nexus UI (latency-based):
  https://${GLOBAL_UI_HOST}
EOF
fi

cat <<EOF

Regional Docker endpoints (TLS):
  docker.io         -> https://${DOCKERHUB_HOST}
  ghcr.io           -> https://${GHCR_HOST}
  quay.io           -> https://${QUAY_HOST}
  public.ecr.aws    -> https://${ECR_HOST}
  registry.k8s.io   -> https://${K8S_HOST}
  us-docker.pkg.dev -> https://${GAR_HOST}
  gcr.io            -> https://${GCR_HOST}
EOF

if [[ -n "${GLOBAL_UI_HOST}" ]]; then
  cat <<EOF

Global Docker endpoints (TLS):
  docker.io         -> https://${GLOBAL_DOCKERHUB_HOST}
  ghcr.io           -> https://${GLOBAL_GHCR_HOST}
  quay.io           -> https://${GLOBAL_QUAY_HOST}
  public.ecr.aws    -> https://${GLOBAL_ECR_HOST}
  registry.k8s.io   -> https://${GLOBAL_K8S_HOST}
  us-docker.pkg.dev -> https://${GLOBAL_GAR_HOST}
  gcr.io            -> https://${GLOBAL_GCR_HOST}
EOF
fi

if [[ -n "${GLOBAL_UI_HOST}" ]]; then
  cat <<EOF

Global TLS cert (must be supplied out of band, not issued by Caddy):
  ${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.crt
  ${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.key
EOF
fi

cat <<EOF

Blob store used for created repos:
  ${BLOBSTORE_NAME}

Regional TLS mode:
  ENABLE_DNS_CHALLENGE=${ENABLE_DNS_CHALLENGE}

IMPORTANT (one-time):
  In Nexus UI: Settings -> Security -> Realms
  Move "Docker Bearer Token Realm" to Active.
  (Required for Docker clients + anonymous pulls.)

EOF
