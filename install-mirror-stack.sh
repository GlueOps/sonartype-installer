#!/usr/bin/env bash
# Build a caching pull-through mirror for the public container registries, APT
# suites and Helm charts a Kubernetes cluster pulls from -- without Nexus.
#
#   sudo BASE_DOMAIN=repo.example.com ACME_EMAIL=admin@example.com \
#        bash install-mirror-stack.sh
#
# WHY THIS EXISTS
# Nexus Repository Community Edition enforces usage limits from 15 October 2026:
# 40,000 components OR 100,000 requests per day, and exceeding either blocks
# *adding new components* until you are under both. For a deployment that is
# entirely proxy repositories, adding a component is what a cache miss IS -- so
# going over the request cap does not throttle the mirror, it stops it caching
# anything it has not already cached. install.sh in this repository still builds
# the Nexus stack, and is kept for deployments that stay under the limits.
#
# WHAT IT BUILDS
#   21 apt suites       -> apt-cacher-ultra, 21 [[mirror]] routes (see APT_REPOS)
#    6 kubernetes apt   -> apt-cacher-ng, 6 Remap entries (see APT_FLAT_REPOS)
#    7 registries      -> ghcr.io/glueops/registry in pull-through mode, one per
#                          upstream (see REGISTRY_IMAGE)
#    4 helm + 6 raw     -> Caddy reverse_proxy, straight to the upstream
# No licence meter, no admin user, no EULA, no realm to switch on by hand.
#
# Every cache is plain local disk. Upstream is explicit that a pull-through
# registry cache uses the filesystem storage driver, and all six raw proxies are
# always-revalidate, so no HTTP cache module is needed and this runs the stock
# caddy:2 image.
#
# MIGRATING FROM NEXUS
# If a Nexus stack from install.sh is present, it is STOPPED, NOT DELETED, and
# its TLS material is carried across first. Rollback is a compose up in the old
# stack directory. On a host with no Nexus, that whole phase is skipped.
#
# REQUIRED
#   BASE_DOMAIN   the regional hostname, e.g. repo.example.com
#   ACME_EMAIL    contact address for Let's Encrypt
#
# OPTIONAL
#   GLOBAL_BASE_DOMAIN  a second, region-independent hostname served by every
#                       mirror behind a geo/latency DNS record. Its certificate
#                       is NOT obtained here: a name that resolves to a different
#                       server on each lookup can never pass HTTP-01, so the same
#                       wildcard is issued once elsewhere and copied to every
#                       host as ${STACK_DIR}/certs/${GLOBAL_CERT_NAME}.{crt,key}.
#   GLOBAL_CERT_NAME    basename of that pre-issued pair. Defaults to
#                       GLOBAL_BASE_DOMAIN.
#   STACK_DIR           default /opt/mirror-stack
#   OLD_STACK_DIR       default /opt/nexus-stack
#   REGISTRY_IMAGE      registry image, tag@digest (default: pinned ghcr.io/glueops/registry)
#   LOG_MAX_SIZE        per-container log file size before rotation, default 50m
#   LOG_MAX_FILES       rotated log files kept per container, default 5
#   APT_ARCHITECTURES   architectures apt-cacher-ultra adopts, default "amd64 arm64"
#   DRY_RUN=1           generate the config files and stop
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/mirror-stack}"
OLD_STACK_DIR="${OLD_STACK_DIR:-/opt/nexus-stack}"
DRY_RUN="${DRY_RUN:-0}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-50m}"
LOG_MAX_FILES="${LOG_MAX_FILES:-5}"

GLOBAL_BASE_DOMAIN="${GLOBAL_BASE_DOMAIN:-}"
GLOBAL_CERT_NAME="${GLOBAL_CERT_NAME:-${GLOBAL_BASE_DOMAIN}}"
ACME_EMAIL="${ACME_EMAIL:-}"

ACNG_UID="${ACNG_UID:-8142}"
ACU_UID="${ACU_UID:-8143}"

# apt-cacher-ultra (https://github.com/linsomniac/apt-cacher-ultra) publishes a
# static linux-amd64 binary per release and no container image, so the image is
# built here from that binary, checked against the release's SHA256SUMS. Bump
# the version and the digest together.
ACU_VERSION="${ACU_VERSION:-1.0.2}"
ACU_SHA256="${ACU_SHA256:-085a0dff37f41baa70b82a3ce8bffca0b899b0488cd3f50f68715564ba8b5343}"

# Adoption fetches every per-architecture index a suite declares, so each extra
# architecture is another set of Packages files per suite per change. A client
# on an architecture not listed here gets a 404 for its Packages index.
APT_ARCHITECTURES="${APT_ARCHITECTURES:-amd64 arm64}"

# The helm and raw cache. Charts and release binaries are small next to
# container layers; this is a ceiling, not an allocation.
NGINX_CACHE_MAX_SIZE="${NGINX_CACHE_MAX_SIZE:-20g}"

# Upstream Distribution 3.1.1 plus one fix so it can proxy public.ecr.aws, which
# stock registry:2/registry:3 cannot (distribution#4383): ECR Public answers HEAD
# on a blob with 401, and the proxy HEADs every blob before fetching it.
# https://github.com/GlueOps/registry
REGISTRY_IMAGE="${REGISTRY_IMAGE:-ghcr.io/glueops/registry:v0.0.2@sha256:8cb6fbe5b2e5b969c917026d3f323fcdfceb5d7dab2c1960e26bccd852ca0e82}"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "==> $*"; }

BASE_DOMAIN="${1:-${BASE_DOMAIN:-}}"
[[ -n "${BASE_DOMAIN}" ]] || die "BASE_DOMAIN is required (or pass the hostname as the first argument)"
[[ -n "${ACME_EMAIL}" ]] || die "ACME_EMAIL is required"

if [[ "${DRY_RUN}" != "1" ]]; then
  [[ "${EUID}" -eq 0 ]] || die "must run as root: sudo $0 ${BASE_DOMAIN}"
  command -v docker >/dev/null || die "docker is required"
fi

# ---------------------------------------------------------------------------
# The repository tables. These are the 44 proxies from install.sh, regrouped by
# what actually serves them. Every name here is a URL clients already use, so a
# name is not free to change.
# ---------------------------------------------------------------------------

# name:subdomain:hostport:upstream -- each gets a REGISTRY_IMAGE container in
# pull-through mode, caching on local disk.
REGISTRIES=(
  "dockerhub:dockerhub:5000:https://registry-1.docker.io"
  "ghcr:ghcr:5001:https://ghcr.io"
  "quay:quay:5002:https://quay.io"
  "ecr:ecr:5003:https://public.ecr.aws"
  "k8s:k8s:5004:https://registry.k8s.io"
  "gcp:gcp:5005:https://us-docker.pkg.dev"
  "gcr:gcr:5006:https://gcr.io"
)

# subdomain:namespace -- where a registry keeps its single-segment "official"
# images.
#
# Docker Hub keeps them under library/, and the docker daemon adds that prefix
# only when it is talking to Hub directly. Through a mirror hostname it sends
# whatever the user typed, so `docker pull <mirror>/nginx:trixie-perl` asks for
# /v2/nginx and gets "manifest unknown" while /v2/library/nginx succeeds.
#
# A separate table rather than a field on REGISTRIES: the two change for
# different reasons, and those records are colon separated while a URL contains
# "://", so a field added after the upstream is handed a fragment of it.
OFFICIAL_NAMESPACE=(
  "dockerhub:library"
)

# name|upstream -- apt-cacher-ultra, one [[mirror]] route each. Pipe separated,
# because the upstream is a URL.
#
# apt-cacher-ultra serves cached metadata from disk and checks upstream in the
# background, and publishes a new InRelease only once every index it names has
# been fetched and verified. So an outage costs nothing on a cache hit. Under
# apt-cacher-ng the same outage turned every InRelease into a 503 after ~90s,
# and a node with no package lists could not install anything.
#
# Several names on one upstream share a cache: the key is the upstream URL, so
# the nine ubuntu-* names hold one copy of pool/, as the Remap grouping did.
# archive.ubuntu.com carries every suite including -security.
# debian-security is a genuinely separate archive with its own pool/.
APT_REPOS=(
  "ubuntu-jammy|http://archive.ubuntu.com/ubuntu"
  "ubuntu-jammy-updates|http://archive.ubuntu.com/ubuntu"
  "ubuntu-jammy-security|http://archive.ubuntu.com/ubuntu"
  "ubuntu-noble|http://archive.ubuntu.com/ubuntu"
  "ubuntu-noble-updates|http://archive.ubuntu.com/ubuntu"
  "ubuntu-noble-security|http://archive.ubuntu.com/ubuntu"
  "ubuntu-resolute|http://archive.ubuntu.com/ubuntu"
  "ubuntu-resolute-updates|http://archive.ubuntu.com/ubuntu"
  "ubuntu-resolute-security|http://archive.ubuntu.com/ubuntu"
  "debian-bookworm|https://deb.debian.org/debian"
  "debian-bookworm-updates|https://deb.debian.org/debian"
  "debian-bookworm-security|https://security.debian.org/debian-security"
  "debian-trixie|https://deb.debian.org/debian"
  "debian-trixie-updates|https://deb.debian.org/debian"
  "debian-trixie-security|https://security.debian.org/debian-security"
  "docker-ubuntu-jammy|https://download.docker.com/linux/ubuntu"
  "docker-ubuntu-noble|https://download.docker.com/linux/ubuntu"
  "docker-ubuntu-resolute|https://download.docker.com/linux/ubuntu"
  "docker-debian-bookworm|https://download.docker.com/linux/debian"
  "docker-debian-trixie|https://download.docker.com/linux/debian"
  # distribution=any against a remote already ending in /any/, so the upstream
  # path really is .../helm-debian/any/dists/any/. Preserved verbatim.
  "helm-apt|https://packages.buildkite.com/helm-linux/helm-debian/any"
)

# Flat repositories -- `deb <url>/ /`, no dists/<suite>/ -- stay on
# apt-cacher-ng, with the Remap entries in acng.conf.
#
# apt-cacher-ultra 1.0.2 only recognises a suite under dists/<suite>/. A flat
# repository's InRelease is cached on first fetch and then served forever:
# verified with a local upstream whose InRelease changed, which was still served
# the original 100s later, after a single upstream request, and never produced a
# freshness check. pkgs.k8s.io publishes every minor as a flat repository, so
# moving these would freeze nodes on the first kubelet patch release seen.
# Move them when apt-cacher-ultra refreshes flat repositories.
APT_FLAT_REPOS=(
  kubernetes-v1-32 kubernetes-v1-33 kubernetes-v1-34
  kubernetes-v1-35 kubernetes-v1-36 kubernetes-v1-37
)

# host|fingerprint|key URL -- signing keys apt-cacher-ultra does not embed.
#
# It verifies every InRelease before adopting it, against its built-in Ubuntu
# and Debian archive keys plus whatever is in its keyring directory. The keys
# below are fetched into that directory on each run, and pinned to their
# fingerprint with a [[trusted_signer]] rule, so a key served from anywhere else
# is refused at adoption rather than trusted. A refused adoption keeps serving
# the previous snapshot.
APT_SIGNERS=(
  "download.docker.com|9DC858229FC7DD38854AE2D88D81803C0EBFCD88|https://download.docker.com/linux/ubuntu/gpg"
  "packages.buildkite.com|DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6|https://packages.buildkite.com/helm-linux/helm-debian/gpgkey"
)

# name:upstream host:upstream path prefix
# Helm chart repositories: an index.yaml plus .tgz files over plain HTTPS.
HELM_REPOS=(
  "helm-stable:charts.helm.sh:/stable"
  "helm-tigera:docs.tigera.io:/calico/charts"
  "helm-metrics-server:kubernetes-sigs.github.io:/metrics-server"
  "helm-containeroo:charts.containeroo.ch:"
)

# Raw HTTP proxies. Every one of these had contentMaxAge=0 under Nexus -- always
# revalidate -- because they are stable paths whose content moves. A plain
# reverse_proxy is a faithful replacement for that: no local copy to go stale.
# This is why the stack needs no HTTP cache module and runs the stock caddy:2.
RAW_REPOS=(
  "raw-k8s:dl.k8s.io:"
  "raw-helm:get.helm.sh:"
  "raw-docker:download.docker.com:"
  "raw-buildkite-helm:packages.buildkite.com:/helm-linux/helm-debian"
  "raw-pkgs-k8s:pkgs.k8s.io:"
  "raw-github:github.com:"
)

# external-prefix|local-route -- where a Helm index.yaml points, and where it
# should point instead.
#
# A chart index carries absolute download URLs. Nexus rewrote them to itself;
# Caddy cannot rewrite a response body at all, so until now `helm install`
# fetched the index from the mirror and the chart from GitHub. nginx does the
# rewrite, and the route it rewrites to has to be one that can serve the thing --
# which is why following redirects server-side is part of the same job rather
# than a separate nicety.
#
# Verified against the live indexes: 219 chart URLs across tigera,
# metrics-server and containeroo point at github.com, and 11652 in the archived
# helm-stable point at charts.helm.sh.
#
# Pipe separated, because both halves contain colons.
CHART_URL_REWRITES=(
  "https://github.com/|/repository/raw-github/"
  "https://charts.helm.sh/stable/|/repository/helm-stable/"
)

# REDIRECTS ARE FOLLOWED SERVER-SIDE BY NGINX
# github.com answers a release download with a 302 to a CDN, pkgs.k8s.io and
# packages.buildkite.com do the same. Handing that redirect back to the client
# means the client needs egress to the CDN, nothing is cached, and an upstream
# outage is a hard failure -- which is the opposite of what a mirror is for.
#
# nginx follows them with proxy_intercept_errors plus a named location that
# proxies to $upstream_http_location. The cache key stays the ORIGINAL request
# path, not the redirect target: buildkite's CloudFront URLs are signed and
# expiring and GitHub's CDN hostname has already changed once, so keying on the
# target would mean never getting a cache hit.

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
CERT_SRC=""
if [[ "${DRY_RUN}" != "1" && -n "${GLOBAL_BASE_DOMAIN}" ]]; then
  log "Preflight: the wildcard must exist to be carried across"
  # First run takes it from the Nexus stack. Every run after that -- including
  # after /opt/nexus-stack has been purged -- finds it already in place here.
  # Checking only the old location would turn a re-run into a hard failure the
  # moment the old stack is reclaimed, which is exactly when nobody expects it.
  for d in "${OLD_STACK_DIR}" "${STACK_DIR}"; do
    if [[ -s "${d}/certs/${GLOBAL_CERT_NAME}.crt" && -s "${d}/certs/${GLOBAL_CERT_NAME}.key" ]]; then
      CERT_SRC="${d}/certs"; break
    fi
  done
  [[ -n "${CERT_SRC}" ]] || die "no ${GLOBAL_CERT_NAME} wildcard in ${OLD_STACK_DIR}/certs or ${STACK_DIR}/certs.
Caddy cannot reissue it -- the name geo-resolves to a different mirror on each
lookup, so HTTP-01 can never complete. Run the \"Renew wildcard cert\" workflow
first, then retry. Nothing has been changed."
  echo "    wildcard found in ${CERT_SRC}, expires: $(openssl x509 -noout -enddate \
    -in "${CERT_SRC}/${GLOBAL_CERT_NAME}.crt" | cut -d= -f2)"
fi

# docker compose up -d recreates a container when its *service definition*
# changes -- image, environment, the list of volumes. It does not notice that
# the contents of a bind-mounted file changed, so a run that alters only the
# Caddyfile, acng.conf or the apt-cacher-ultra config brings up nothing and
# silently leaves the old config serving. That has to be handled explicitly
# below, and it needs the old checksums taken before anything is rewritten.
cfg_sum() { [[ -f "$1" ]] && sha256sum "$1" | cut -d" " -f1 || echo "absent"; }
# apt-cacher-ultra reads its keyring at startup too, so a changed key needs the
# same restart as a changed config. On a first run none of these exist yet, and
# under pipefail a failing cat would kill the script silently at the assignment
# below -- so absent files hash as nothing, which still differs from the result.
acu_sum() {
  { cat "${STACK_DIR}/apt-cacher-ultra.toml" "${STACK_DIR}"/apt-keys/*.asc 2>/dev/null || true; } \
    | sha256sum | cut -d" " -f1
}
CADDY_SUM_BEFORE="$(cfg_sum "${STACK_DIR}/Caddyfile")"
ACNG_SUM_BEFORE="$(cfg_sum "${STACK_DIR}/acng.conf")"
ACU_SUM_BEFORE="$(acu_sum)"

# A host with no room left fails deep inside `docker build`, as "You don't have
# enough free space in /var/cache/apt/archives/" buried in a layer log -- which
# reads like a broken Dockerfile rather than a full disk. Check first and say so.
# This runs before anything is written and long before Nexus is stopped, and it
# matters more now that a registry cache only grows.
if [[ "${DRY_RUN}" != "1" ]]; then
  need_mb=2048
  for path in "$(dirname "${STACK_DIR}")" /var/lib/docker; do
    [[ -d "${path}" ]] || continue
    free_mb="$(df -Pm "${path}" | awk 'NR==2 {print $4}')"
    if [[ -n "${free_mb}" && "${free_mb}" -lt "${need_mb}" ]]; then
      df -h "${path}" >&2
      die "only ${free_mb}MB free on ${path}, need at least ${need_mb}MB.

Building the images alone needs a few hundred MB, and a registry cache only
grows. Nothing has been changed and the current stack is still serving.

To reclaim space:
  docker system prune -af                 # unused images and layers
  du -sh /opt/* /var/lib/docker/* 2>/dev/null | sort -h | tail
On a host already migrated, the stopped Nexus stack is usually the largest
thing on disk and is safe to remove once the new stack has proven itself:
  rm -rf /opt/nexus ${OLD_STACK_DIR}"
    fi
  done
fi

log "Preparing ${STACK_DIR}"
mkdir -p "${STACK_DIR}"/{certs,caddy-data,caddy-config,apt-cache,apt-log,apt-cache-ultra,apt-keys,registries,content-cache,content-log}
mkdir -p "${STACK_DIR}/site"
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r name _ _ _ <<<"${entry}"
  mkdir -p "${STACK_DIR}/registries/${name}"
done

if [[ "${DRY_RUN}" != "1" ]]; then
  chown -R "${ACNG_UID}:${ACNG_UID}" "${STACK_DIR}/apt-cache" "${STACK_DIR}/apt-log"
  chown -R "${ACU_UID}:${ACU_UID}" "${STACK_DIR}/apt-cache-ultra"

  # Fetched on every run so a rotated key is picked up, but only replaced when
  # the download succeeds: a re-run during an upstream outage keeps the key it
  # has. With no key at all, adoption for that host would be refused forever --
  # the suite serves whatever it first cached and never updates -- so that is a
  # hard stop, before anything is running. The fingerprint pin is enforced by
  # apt-cacher-ultra's [[trusted_signer]], not here.
  log "Fetching apt signing keys"
  for entry in "${APT_SIGNERS[@]}"; do
    IFS='|' read -r host _ url <<<"${entry}"
    key="${STACK_DIR}/apt-keys/${host}.asc"
    if curl -fsSL --max-time 30 "${url}" -o "${key}.new" && [[ -s "${key}.new" ]]; then
      mv "${key}.new" "${key}"
    else
      rm -f "${key}.new"
      [[ -s "${key}" ]] || die "could not fetch the signing key for ${host} from ${url}, and none is cached.
apt-cacher-ultra would refuse every update for that repository. Nothing has
been stopped; re-run once ${url} is reachable."
      echo "    ${host}: fetch failed, keeping the cached key"
    fi
  done

  # registry:2 left expiry state behind. With REGISTRY_PROXY_TTL=0 it's ignored, but
  # every entry is long past due, so setting a TTL later would purge the whole cache
  # at once. Remove it.
  rm -f "${STACK_DIR}"/registries/*/scheduler-state.json

  if [[ -n "${CERT_SRC}" && "${CERT_SRC}" != "${STACK_DIR}/certs" ]]; then
    log "Carrying TLS state across from ${OLD_STACK_DIR}"
    cp -a "${CERT_SRC}/." "${STACK_DIR}/certs/"
  else
    log "Wildcard already in place"
  fi
  if compgen -G "${STACK_DIR}/certs/*.crt" >/dev/null; then
    chmod 644 "${STACK_DIR}"/certs/*.crt
    chmod 600 "${STACK_DIR}"/certs/*.key
  fi
  # Same reasoning as the wildcard: on a re-run this is already here, and saying
  # "the regional certs will be reissued" at a host that holds them would be
  # both wrong and alarming.
  if [[ -n "$(ls -A "${STACK_DIR}/caddy-data" 2>/dev/null)" ]]; then
    echo "    ACME account and regional certs already in place; nothing will be reissued"
  elif [[ -d "${OLD_STACK_DIR}/caddy-data" ]]; then
    cp -a "${OLD_STACK_DIR}/caddy-data/." "${STACK_DIR}/caddy-data/"
    echo "    ACME account and regional certs carried across; nothing will be reissued"
  else
    echo "    WARNING: no caddy-data found; the 8 regional names will be reissued"
  fi
fi

# ---------------------------------------------------------------------------
# apt-cacher-ng: the flat kubernetes repositories only (see APT_FLAT_REPOS)
# ---------------------------------------------------------------------------
log "Writing Dockerfile.acng"
cat > "${STACK_DIR}/Dockerfile.acng" <<EOF
FROM debian:trixie-slim
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      apt-cacher-ng ca-certificates curl \\
 && rm -rf /var/lib/apt/lists/*
RUN usermod -u ${ACNG_UID} apt-cacher-ng \\
 && groupmod -g ${ACNG_UID} apt-cacher-ng \\
 && chown -R ${ACNG_UID}:${ACNG_UID} \\
      /etc/apt-cacher-ng /var/cache/apt-cacher-ng /var/log/apt-cacher-ng \\
 && install -d -o ${ACNG_UID} -g ${ACNG_UID} /run/apt-cacher-ng
USER apt-cacher-ng
ENTRYPOINT ["/usr/sbin/apt-cacher-ng"]
CMD ["-c", "/etc/apt-cacher-ng", "ForeGround=1"]
EOF

log "Writing acng.conf"
cat > "${STACK_DIR}/acng.conf" <<'EOF'
CacheDir: /var/cache/apt-cacher-ng
LogDir: /var/log/apt-cacher-ng
Port: 3142
BindAddress: 0.0.0.0

# Not an open forward proxy. Every reachable repository is named in a Remap
# below; anything else is refused. Caddy now routes public traffic here, so an
# empty PassThroughPattern is what keeps this from becoming an open relay.
ForwardBtsSoap: 0
PassThroughPattern: ^$

ExThreshold: 24
VerboseLog: 1
ReportPage: acng-report.html

# pkgs.k8s.io publishes each minor as an independent flat repository: no shared
# pool, so merging would be wrong.
Remap-k8s132: /repository/kubernetes-v1-32 ; https://pkgs.k8s.io/core:/stable:/v1.32/deb
Remap-k8s133: /repository/kubernetes-v1-33 ; https://pkgs.k8s.io/core:/stable:/v1.33/deb
Remap-k8s134: /repository/kubernetes-v1-34 ; https://pkgs.k8s.io/core:/stable:/v1.34/deb
Remap-k8s135: /repository/kubernetes-v1-35 ; https://pkgs.k8s.io/core:/stable:/v1.35/deb
Remap-k8s136: /repository/kubernetes-v1-36 ; https://pkgs.k8s.io/core:/stable:/v1.36/deb
Remap-k8s137: /repository/kubernetes-v1-37 ; https://pkgs.k8s.io/core:/stable:/v1.37/deb
EOF

# ---------------------------------------------------------------------------
# apt-cacher-ultra: every repository in APT_REPOS
# ---------------------------------------------------------------------------
log "Writing Dockerfile.acu"
cat > "${STACK_DIR}/Dockerfile.acu" <<EOF
FROM debian:trixie-slim
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\
      ca-certificates curl \\
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSLo /usr/local/bin/apt-cacher-ultra \\
      https://github.com/linsomniac/apt-cacher-ultra/releases/download/${ACU_VERSION}/apt-cacher-ultra-${ACU_VERSION}-linux-amd64 \\
 && echo "${ACU_SHA256}  /usr/local/bin/apt-cacher-ultra" | sha256sum -c - \\
 && chmod 0755 /usr/local/bin/apt-cacher-ultra \\
 && groupadd -g ${ACU_UID} apt-cacher-ultra \\
 && useradd -u ${ACU_UID} -g ${ACU_UID} -d /var/cache/apt-cacher-ultra -s /usr/sbin/nologin apt-cacher-ultra
USER apt-cacher-ultra
ENTRYPOINT ["/usr/local/bin/apt-cacher-ultra", "-config", "/etc/apt-cacher-ultra/config.toml"]
EOF

log "Writing apt-cacher-ultra.toml"
{
  echo "# Generated by install-mirror-stack.sh. Reference:"
  echo "# https://github.com/linsomniac/apt-cacher-ultra/blob/${ACU_VERSION}/docs/configuration.md"
  echo "[cache]"
  echo "dir    = \"/var/cache/apt-cacher-ultra\""
  echo "listen = \"0.0.0.0:3142\""
  echo
  echo "[upstream]"
  echo "# Every host is allowed, and that is not an open relay: Caddy forwards only"
  echo "# /repository/<name>/ paths, and a path matching no [[mirror]] route is a 400."
  echo "# An allowlist would also have to name the CDNs upstreams redirect to, which"
  echo "# they are free to change."
  echo "allowed_host_regex = ['^.*\$']"
  echo
  echo "[adoption]"
  echo "# Without adoption a changed InRelease is logged and never served: clients"
  echo "# would keep the first copy ever cached."
  echo "enabled      = true"
  echo "keyring_dirs = [\"/etc/apt-cacher-ultra/keys\"]"
  printf 'architectures = [%s]\n' "$(printf '"%s", ' ${APT_ARCHITECTURES} | sed 's/, $//')"
  echo
  echo "[gc]"
  echo "# A .deb nobody requested for this long, and that is not among the newest"
  echo "# versions, becomes collectable. The default is 7 days; a package a node"
  echo "# installs once a month at bootstrap should survive an outage too. This is"
  echo "# apt-cacher-ng's ExThreshold rounded up."
  echo "url_path_ttl = \"720h\""
  echo
  echo "[admin]"
  echo "# /healthz, /metrics and the status page. Inside the container only: the"
  echo "# port is not published and POST /reconcile is unauthenticated."
  echo "listen = \"127.0.0.1:6789\""
  echo
  echo "[log]"
  echo "format = \"json\""
  echo
  echo "[tls_mitm]"
  echo "# Clients reach this by path through Caddy, never as a forward proxy, so"
  echo "# there is no CONNECT to intercept and no CA to distribute."
  echo "enabled = false"
  for entry in "${APT_SIGNERS[@]}"; do
    IFS='|' read -r host fpr _ <<<"${entry}"
    echo
    echo "[[trusted_signer]]"
    echo "match_canonical_host = '^${host//./\\.}\$'"
    echo "fingerprints = ['${fpr}']"
  done
  for entry in "${APT_REPOS[@]}"; do
    IFS='|' read -r name upstream <<<"${entry}"
    echo
    echo "[[mirror]]"
    echo "prefix   = \"/repository/${name}\""
    echo "upstream = \"${upstream}\""
  done
} > "${STACK_DIR}/apt-cacher-ultra.toml"


# ---------------------------------------------------------------------------
# nginx: the content cache for helm and raw
# ---------------------------------------------------------------------------
# Caddy fronts everything and terminates TLS; this sits behind it and does the
# three things Caddy cannot: keep a copy, serve that copy when the upstream is
# unreachable, and rewrite a response body.
log "Writing nginx.conf"
{
  echo "worker_processes auto;"
  echo "error_log /var/log/nginx/error.log warn;"
  echo "events { worker_connections 2048; }"
  echo "http {"
  echo "  include /etc/nginx/mime.types;"
  echo "  default_type application/octet-stream;"
  echo "  sendfile on;"
  echo "  server_tokens off;"
  echo
  echo "  # Cache status is the only thing worth logging here -- Caddy already"
  echo "  # records the request. HIT/MISS/STALE is what says whether this is"
  echo "  # earning its keep."
  echo "  log_format cache '\$status \$upstream_cache_status \$body_bytes_sent \$request_uri';"
  echo "  access_log /var/log/nginx/access.log cache;"
  echo
  echo "  # Docker's embedded DNS. Required because the redirect-following"
  echo "  # location proxies to a hostname only known at request time."
  echo "  resolver 127.0.0.11 ipv6=off valid=30s;"
  echo "  resolver_timeout 5s;"
  echo
  echo "  proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=content:64m"
  echo "                   max_size=${NGINX_CACHE_MAX_SIZE} inactive=365d use_temp_path=off;"
  echo
  echo "  # The original request path, never the redirect target. buildkite hands"
  echo "  # out signed expiring CloudFront URLs and GitHub's asset CDN hostname has"
  echo "  # already changed once; keying on either would never hit."
  echo "  proxy_cache_key \"\$host\$request_uri\";"
  echo "  proxy_cache_lock on;"
  echo "  proxy_cache_lock_timeout 60s;"
  echo "  proxy_cache_background_update on;"
  echo "  proxy_cache_revalidate on;"
  echo
  echo "  # The outage behaviour this whole component exists for: if the upstream"
  echo "  # errors, times out or 5xxes, serve what we already have."
  echo "  proxy_cache_use_stale error timeout updating"
  echo "                        http_500 http_502 http_503 http_504 http_429;"
  echo
  echo "  proxy_ssl_server_name on;"
  echo "  proxy_ssl_protocols TLSv1.2 TLSv1.3;"
  echo "  proxy_http_version 1.1;"
  echo "  proxy_connect_timeout 15s;"
  echo "  proxy_read_timeout 300s;"
  echo "  proxy_send_timeout 300s;"
  echo "  proxy_buffering on;"
  echo "  # GitHub's 302 to its asset CDN carries a signed URL hundreds of bytes"
  echo "  # long, and the default 4k header buffer cannot hold the response."
  echo "  # Without this every redirect-following fetch fails as 502 \"upstream"
  echo "  # sent too big header\"."
  echo "  proxy_buffer_size 32k;"
  echo "  proxy_buffers 8 32k;"
  echo "  proxy_busy_buffers_size 64k;"
  echo "  # Deliberately NOT proxy_max_temp_file_size 0: nginx writes a response"
  echo "  # to a temp file on its way into the cache, so disabling that silently"
  echo "  # stops anything larger than the buffers from ever being cached."
  echo "  proxy_max_temp_file_size 2048m;"
  echo
  echo "  # These are third-party origins fetched as an ordinary client, which is"
  echo "  # what Nexus did. packages.buildkite.com answers any request carrying an"
  echo "  # X-Forwarded-Proto with a 301 to its marketing site."
  echo "  proxy_set_header X-Forwarded-For \"\";"
  echo "  proxy_set_header X-Forwarded-Proto \"\";"
  echo "  proxy_set_header X-Forwarded-Host \"\";"
  echo
  echo "  server {"
  echo "    listen 8080;"
  echo "    server_name _;"
  echo
  echo "    location = /healthz { return 200 \"ok\\n\"; }"
  echo

  # ---- helm: cache, and rewrite the chart URLs in index.yaml ----
  for entry in "${HELM_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "    location /repository/${name}/ {"
    echo "      proxy_pass https://${host}${path}/;"
    echo "      proxy_set_header Host ${host};"
    echo "      proxy_cache content;"
    echo "      # An index moves; a chart tarball at a version does not."
    echo "      proxy_cache_valid 200 206 5m;"
    echo "      proxy_intercept_errors on;"
    echo "      error_page 301 302 303 307 308 = @follow_redirect;"
    echo
    echo "      # sub_filter cannot touch a compressed body, and every one of"
    echo "      # these indexes serves gzip when asked. Without this the rewrite"
    echo "      # silently does nothing at all."
    echo "      proxy_set_header Accept-Encoding \"\";"
    echo "      sub_filter_once off;"
    echo "      sub_filter_types text/yaml application/x-yaml application/yaml text/plain;"
    for rw in "${CHART_URL_REWRITES[@]}"; do
      ext="${rw%%|*}"; loc="${rw#*|}"
      echo "      sub_filter '${ext}' 'https://\$host${loc}';"
    done
    echo "      gzip on;"
    echo "      gzip_types text/yaml application/x-yaml application/yaml text/plain;"
    echo "    }"
    echo
  done

  # ---- raw: cache, and follow redirects rather than handing them back ----
  for entry in "${RAW_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "    location /repository/${name}/ {"
    echo "      proxy_pass https://${host}${path}/;"
    echo "      proxy_set_header Host ${host};"
    echo "      proxy_cache content;"
    echo "      proxy_cache_valid 200 206 30d;"
    echo "      proxy_intercept_errors on;"
    echo "      error_page 301 302 303 307 308 = @follow_redirect;"
    echo "    }"
    echo
  done

  echo "    # Shared by every location above. \$upstream_http_location is the"
  echo "    # Location header of the response we just intercepted; the cache key"
  echo "    # set at http level keeps this stored under the original path."
  echo "    location @follow_redirect {"
  echo "      internal;"
  echo "      set \$redirect_target \$upstream_http_location;"
  echo "      proxy_pass \$redirect_target;"
  echo "      proxy_set_header Host \"\";"
  echo "      proxy_set_header Authorization \"\";"
  echo "      proxy_cache content;"
  echo "      proxy_cache_valid 200 206 30d;"
  echo "      # One hop only. A redirect loop must fail, not recurse."
  echo "      proxy_intercept_errors off;"
  echo "    }"
  echo "  }"
  echo "}"
} > "${STACK_DIR}/nginx.conf"

# ---------------------------------------------------------------------------
# Landing page. The Nexus UI is gone and nothing replaces it, so the bare
# hostname serves what is actually useful: the repository list, and a /healthz
# for the deploy workflow to assert on.
# ---------------------------------------------------------------------------
log "Writing landing page"
{
  echo "<!doctype html><meta charset=utf-8><title>${GLOBAL_BASE_DOMAIN} mirror</title>"
  echo "<style>body{font:14px/1.5 system-ui,sans-serif;max-width:52rem;margin:3rem auto;padding:0 1rem}"
  echo "code{background:#f4f4f5;padding:.1em .35em;border-radius:3px}h2{margin-top:2rem;font-size:1rem}</style>"
  echo "<h1>${BASE_DOMAIN}</h1><p>Pull-through mirror. Nothing here is a source of truth; every path proxies an upstream.</p>"
  echo "<h2>Container registries</h2><ul>"
  for entry in "${REGISTRIES[@]}"; do
    IFS=: read -r _ sub _ up <<<"${entry}"
    echo "<li><code>${sub}.${BASE_DOMAIN}</code> &rarr; ${up}</li>"
  done
  echo "</ul><h2>APT ($(( ${#APT_REPOS[@]} + ${#APT_FLAT_REPOS[@]} )))</h2><ul>"
  for entry in "${APT_REPOS[@]}"; do
    IFS='|' read -r name upstream <<<"${entry}"
    echo "<li><code>/repository/${name}/</code> &rarr; ${upstream}</li>"
  done
  for r in "${APT_FLAT_REPOS[@]}"; do echo "<li><code>/repository/${r}/</code></li>"; done
  echo "</ul><h2>Helm</h2><ul>"
  for entry in "${HELM_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "<li><code>/repository/${name}/</code> &rarr; https://${host}${path}</li>"
  done
  echo "</ul><h2>Raw</h2><ul>"
  for entry in "${RAW_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "<li><code>/repository/${name}/</code> &rarr; https://${host}${path}</li>"
  done
  echo "</ul>"
} > "${STACK_DIR}/site/index.html"

# ---------------------------------------------------------------------------
# Caddyfile
# ---------------------------------------------------------------------------
# Regional and global names CANNOT share a site block, and this is the one thing
# in the file that will silently break TLS if it is got wrong.
#
# The pre-issued wildcard is for repo.gpkg.io -- it covers repo.gpkg.io and
# *.repo.gpkg.io, so dockerhub.repo.gpkg.io is in scope. It does NOT cover
# repo.eu-central.gpkg.io or dockerhub.repo.eu-central.gpkg.io: those are a
# different name entirely, not a subdomain of repo.gpkg.io. The regional names
# get their own ACME HTTP-01 certs -- 8 per host, which is the number the
# rebuild rate-limit arithmetic in the README is counting.
#
# So: one block per service for the regional name (ACME), one for the global
# name (static wildcard). A `tls` directive applies to every address on its
# block, which is exactly why merging them would hand the regional names a
# certificate that does not match them.
regional_host() { local sub="${1:-}"; [[ -n "${sub}" ]] && echo "${sub}.${BASE_DOMAIN}" || echo "${BASE_DOMAIN}"; }
global_host()   { local sub="${1:-}"; [[ -n "${sub}" ]] && echo "${sub}.${GLOBAL_BASE_DOMAIN}" || echo "${GLOBAL_BASE_DOMAIN}"; }

official_ns_for() {
  local want="$1" e
  for e in "${OFFICIAL_NAMESPACE[@]}"; do
    [[ "${e%%:*}" == "${want}" ]] && { echo "${e#*:}"; return 0; }
  done
  return 0
}

# The pattern requires the segment after the repository name to be one of
# manifests/blobs/tags, which is what confines it to single-segment names:
# /v2/grafana/grafana/manifests/x has `grafana` followed by `grafana`, so a
# namespaced image is left alone, and /v2/ and /v2/_catalog do not match either.
official_rewrite() {
  echo "  @official path_regexp official ^/v2/([^/]+)/(manifests|blobs|tags)/(.*)\$"
  echo "  rewrite @official /v2/$1/{re.official.1}/{re.official.2}/{re.official.3}"
}

# Build the apt route matchers from the tables above, so the Caddyfile and the
# two caches' configs cannot drift apart silently.
apt_names=()
for entry in "${APT_REPOS[@]}"; do apt_names+=("${entry%%|*}"); done
apt_alternation="$(IFS='|'; echo "${apt_names[*]}")"
apt_flat_alternation="$(IFS='|'; echo "${APT_FLAT_REPOS[*]}")"

log "Writing Caddyfile"
{
  echo "{"
  echo "  email ${ACME_EMAIL}"
  echo "}"
  echo
  # The wildcard is pre-issued and shipped by renew-wildcard.yml. Caddy must be
  # told to use it rather than try to obtain one, or it will fail HTTP-01 on a
  # geo-routed name forever.
  if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
    echo "(globalcert) {"
    echo "  tls /certs/${GLOBAL_CERT_NAME}.crt /certs/${GLOBAL_CERT_NAME}.key"
    echo "}"
    echo
  fi
  # Registry traffic: long timeouts and no response buffering, because a layer
  # pull is a single large streamed body.
  # Structured logs, with a bounded footprint.
  #
  # The console format is for a terminal; these are files nobody tails. json is
  # what makes "which repositories is this mirror actually serving, and how
  # much" a question something can answer.
  #
  # The roll limits are not decoration. Caddy defaults to 100MiB x 10 per log,
  # and this stack writes several of them, so the default ceiling is gigabytes
  # of logs on a host whose whole job is caching. One mirror has already filled
  # its disk once.
  echo "(accesslog) {"
  echo "  log {"
  echo "    output file /data/logs/{args[0]}-access.log {"
  echo "      roll_size 32MiB"
  echo "      roll_keep 4"
  echo "      roll_keep_for 336h"
  echo "    }"
  echo "    format json"
  echo "  }"
  echo "}"
  echo
  echo "(registry_proxy) {"
  echo "  reverse_proxy {args[0]} {"
  echo "    header_up Host {host}"
  echo "    header_up X-Forwarded-Proto {scheme}"
  echo "    flush_interval -1"
  echo "    transport http {"
  echo "      versions 1.1"
  echo "      dial_timeout 300s"
  echo "      response_header_timeout 300s"
  echo "      read_timeout 0"
  echo "      write_timeout 0"
  echo "    }"
  echo "  }"
  echo "}"
  echo

  # ---- the route table, defined once and imported by both site blocks ----
  echo "(mirror_routes) {"
  echo "  handle /healthz {"
  echo "    respond \"ok\" 200"
  echo "  }"
  echo
  echo "  # ---- APT: ${#APT_REPOS[@]} repositories on apt-cacher-ultra ----"
  echo "  @apt path_regexp ^/repository/(${apt_alternation})(/|\$)"
  echo "  handle @apt {"
  echo "    reverse_proxy apt-cache:3142 {"
  echo "      header_up Host {host}"
  echo "    }"
  echo "  }"
  echo
  echo "  # ---- APT: ${#APT_FLAT_REPOS[@]} flat repositories on apt-cacher-ng ----"
  echo "  @apt_flat path_regexp ^/repository/(${apt_flat_alternation})(/|\$)"
  echo "  handle @apt_flat {"
  echo "    reverse_proxy apt-cache-ng:3142 {"
  echo "      header_up Host {host}"
  echo "    }"
  echo "  }"
  echo

  # Caddy adds X-Forwarded-For / -Proto / -Host to every proxied request. That is
  # right for a backend you own and wrong for a third-party origin: these are
  # public CDNs being fetched as an ordinary client, which is what Nexus did.
  # packages.buildkite.com is the proof -- it answers a request carrying any
  # X-Forwarded-Proto with a 301 to its marketing site instead of the signed CDN
  # URL for the key, whether the value says http or https. Strip them.
  #
  # Caddy logs "Unnecessary header_up X-Forwarded-Proto: the reverse proxy's
  # default behavior is to pass headers to the upstream" once per route on load.
  # That warning is spurious: it matches the header name without noticing the
  # leading "-" that makes this a deletion. Verified against a controlled
  # upstream that all three headers do arrive on an unmodified route and none of
  # them arrives on a stripped one. Do not "fix" the warning by removing these.
  strip_forwarded() {
    echo "      header_up -X-Forwarded-For"
    echo "      header_up -X-Forwarded-Proto"
    echo "      header_up -X-Forwarded-Host"
  }

  # Helm and raw both go to nginx, which caches them, serves what it has when
  # the upstream is unreachable, rewrites chart URLs and follows redirects.
  # Caddy keeps only the routing decision; the per-repository table lives in
  # nginx.conf so the two cannot disagree about it.
  content_names=()
  for entry in "${HELM_REPOS[@]}" "${RAW_REPOS[@]}"; do content_names+=("${entry%%:*}"); done
  content_alternation="$(IFS='|'; echo "${content_names[*]}")"

  echo "  # ---- Helm chart repositories and raw HTTP proxies ----"
  echo "  @content path_regexp ^/repository/(${content_alternation})(/|\$)"
  echo "  handle @content {"
  echo "    reverse_proxy content-cache:8080 {"
  echo "      header_up Host {host}"
  echo "      flush_interval -1"
  echo "      transport http {"
  echo "        dial_timeout 15s"
  echo "        response_header_timeout 300s"
  echo "        read_timeout 0"
  echo "        write_timeout 0"
  echo "      }"
  echo "    }"
  echo "  }"
  echo

  echo "  handle {"
  echo "    root * /site"
  echo "    file_server"
  echo "  }"
  echo
  echo "  import accesslog mirror"
  echo "}"
  echo

  # ---- the main hostname: regional gets ACME, global gets the wildcard ----
  echo "$(regional_host) {"
  echo "  import mirror_routes"
  echo "}"
  echo
  if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
    echo "$(global_host) {"
    echo "  import globalcert"
    echo "  import mirror_routes"
    echo "}"
    echo
  fi

  # ---- one pair of sites per registry, same split ----
  for entry in "${REGISTRIES[@]}"; do
    IFS=: read -r name sub _ _ <<<"${entry}"
    echo "$(regional_host "${sub}") {"
    ns="$(official_ns_for "${sub}")"; [[ -n "${ns}" ]] && official_rewrite "${ns}"
    echo "  import registry_proxy registry-${name}:5000"
    echo "  import accesslog ${name}"
    echo "}"
    echo
    if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
      echo "$(global_host "${sub}") {"
      echo "  import globalcert"
      ns="$(official_ns_for "${sub}")"; [[ -n "${ns}" ]] && official_rewrite "${ns}"
      echo "  import registry_proxy registry-${name}:5000"
      echo "  import accesslog ${name}"
      echo "}"
      echo
    fi
  done

} > "${STACK_DIR}/Caddyfile"

# ---------------------------------------------------------------------------
# Registry credential helper (proxy.exec). Anonymous: prints empty credentials.
# The registry runs it directly, so it must be executable.
# ---------------------------------------------------------------------------
log "Writing registry-upstream-creds"
cat > "${STACK_DIR}/registry-upstream-creds" <<'EOF'
#!/bin/sh
cat >/dev/null
echo '{"ServerURL":"","Username":"","Secret":""}'
EOF
chmod 0755 "${STACK_DIR}/registry-upstream-creds"

# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------
log "Writing docker-compose.yml"
# Docker's json-file logs grow without limit unless capped.
compose_logging() {
  echo "    logging:"
  echo "      driver: json-file"
  echo "      options:"
  echo "        max-size: \"${LOG_MAX_SIZE}\""
  echo "        max-file: \"${LOG_MAX_FILES}\""
}
{
  echo "services:"
  echo "  caddy:"
  echo "    image: caddy:2"
  echo "    container_name: mirror-caddy"
  echo "    restart: unless-stopped"
  compose_logging
  echo "    ports:"
  echo "      - \"80:80\""
  echo "      - \"443:443\""
  echo "    volumes:"
  echo "      - ${STACK_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro"
  echo "      - ${STACK_DIR}/site:/site:ro"
  echo "      - ${STACK_DIR}/caddy-data:/data"
  echo "      - ${STACK_DIR}/caddy-config:/config"
  echo "      - ${STACK_DIR}/certs:/certs:ro"
  echo "    depends_on:"
  echo "      - apt-cache"
  echo "      - apt-cache-ng"
  echo "      - content-cache"
  echo
  echo "  content-cache:"
  echo "    image: nginx:alpine"
  echo "    container_name: content-cache"
  echo "    restart: unless-stopped"
  echo "    volumes:"
  echo "      - ${STACK_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro"
  echo "      - ${STACK_DIR}/content-cache:/var/cache/nginx"
  echo "      - ${STACK_DIR}/content-log:/var/log/nginx"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1\"]"
  echo "      interval: 30s"
  echo "      timeout: 5s"
  echo "      retries: 3"
  echo "      start_period: 10s"
  echo
  echo "  apt-cache:"
  echo "    build:"
  echo "      context: ."
  echo "      dockerfile: Dockerfile.acu"
  echo "    container_name: apt-cache"
  echo "    restart: unless-stopped"
  compose_logging
  echo "    volumes:"
  echo "      - ${STACK_DIR}/apt-cacher-ultra.toml:/etc/apt-cacher-ultra/config.toml:ro"
  echo "      - ${STACK_DIR}/apt-keys:/etc/apt-cacher-ultra/keys:ro"
  echo "      - ${STACK_DIR}/apt-cache-ultra:/var/cache/apt-cacher-ultra"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"curl -fsS http://127.0.0.1:6789/healthz >/dev/null\"]"
  echo "      interval: 30s"
  echo "      timeout: 5s"
  echo "      retries: 3"
  echo "      start_period: 10s"
  echo
  echo "  apt-cache-ng:"
  echo "    build:"
  echo "      context: ."
  echo "      dockerfile: Dockerfile.acng"
  echo "    container_name: apt-cache-ng"
  echo "    restart: unless-stopped"
  compose_logging
  echo "    volumes:"
  echo "      - ${STACK_DIR}/acng.conf:/etc/apt-cacher-ng/acng.conf:ro"
  echo "      - ${STACK_DIR}/apt-cache:/var/cache/apt-cacher-ng"
  echo "      - ${STACK_DIR}/apt-log:/var/log/apt-cacher-ng"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"curl -fsS http://127.0.0.1:3142/acng-report.html >/dev/null\"]"
  echo "      interval: 30s"
  echo "      timeout: 5s"
  echo "      retries: 3"
  echo "      start_period: 10s"

  for entry in "${REGISTRIES[@]}"; do
    IFS=: read -r name _ port up <<<"${entry}"
    echo
    echo "  registry-${name}:"
    echo "    image: ${REGISTRY_IMAGE}"
    echo "    container_name: registry-${name}"
    echo "    restart: unless-stopped"
    compose_logging
    echo "    environment:"
    echo "      # Filesystem: the only storage upstream guarantees for a pull-through cache."
    echo "      - REGISTRY_PROXY_REMOTEURL=${up}"
    echo "      - REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry"
    echo "      - REGISTRY_HTTP_ADDR=0.0.0.0:5000"
    echo "      # Never expire: expiry deletes cached manifests, even during an outage."
    echo "      - REGISTRY_PROXY_TTL=0"
    echo "      # Skips the startup probe of the upstream, which panics when it's unreachable."
    echo "      - REGISTRY_PROXY_EXEC_COMMAND=/etc/distribution/registry-upstream-creds"
    echo "      # The image's default config is registry:3's development one: debug"
    echo "      # logging, and a debug/pprof server reachable from other containers."
    echo "      - REGISTRY_LOG_LEVEL=info"
    echo "      - REGISTRY_LOG_FIELDS_ENVIRONMENT=production"
    echo "      - REGISTRY_HTTP_DEBUG_ADDR=127.0.0.1:5001"
    echo "    volumes:"
    echo "      - ${STACK_DIR}/registries/${name}:/var/lib/registry"
    echo "      - ${STACK_DIR}/registry-upstream-creds:/etc/distribution/registry-upstream-creds:ro"
    echo "    ports:"
    echo "      - \"127.0.0.1:${port}:5000\""
  done
} > "${STACK_DIR}/docker-compose.yml"

if [[ "${DRY_RUN}" == "1" ]]; then
  log "DRY_RUN=1: files written to ${STACK_DIR}, nothing started, Nexus untouched"
  exit 0
fi

# ---------------------------------------------------------------------------
# Cutover
# ---------------------------------------------------------------------------
# Build before stopping anything. A failed image build with Nexus already down
# is an outage for no reason.
log "Building images (current stack still serving)"
cd "${STACK_DIR}"
docker compose build

# Pull before stopping anything, for the same reason the build happens first.
#
# `docker compose up` fetches what it does not have, which is after the teardown
# -- so an unreachable registry, an expired credential or a withdrawn tag became
# an outage rather than a refusal. One deploy has already hit this: a stale
# ghcr.io credential on the host turned a public image into "error from
# registry: denied", and the only reason the mirror stayed up is that compose
# happened to fail before it replaced the running containers. That is luck, not
# design.
log "Pulling images (current stack still serving)"
docker compose pull --quiet || die "could not pull one or more images; nothing has been stopped and the current stack is still serving.

A public image failing here usually means this host is sending a stale
credential rather than pulling anonymously -- docker sends any credential it
holds, and an expired one is refused instead of falling back:

  cat /root/.docker/config.json     # an auths entry for the registry
  docker logout <registry>

Then re-run."

if [[ -f "${OLD_STACK_DIR}/docker-compose.yml" ]]; then
  log "Stopping Nexus"
  ( cd "${OLD_STACK_DIR}" && docker compose down --remove-orphans ) || \
    die "could not stop the Nexus stack; the new stack has NOT been started and port 80/443 are still Nexus's"
else
  log "No Nexus stack at ${OLD_STACK_DIR}; nothing to stop"
fi

log "Starting the mirror stack"
cd "${STACK_DIR}"
# --remove-orphans clears containers this compose file no longer declares, such
# as a registry removed from REGISTRIES. Left behind, it keeps running and
# answering, which makes a stale route look healthy.
docker compose up -d --remove-orphans

# Now apply the config changes compose cannot see.
if [[ "$(cfg_sum "${STACK_DIR}/Caddyfile")" != "${CADDY_SUM_BEFORE}" ]]; then
  log "Caddyfile changed, reloading Caddy"
  # --force because a reload is skipped when Caddy judges the config unchanged,
  # and the certificate files it points at can change without the file doing so.
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force \
    || die "Caddy would not load the new config. The previous one is still serving -- check: docker compose -f ${STACK_DIR}/docker-compose.yml logs caddy"
else
  log "Caddyfile unchanged"
fi

if [[ "$(cfg_sum "${STACK_DIR}/acng.conf")" != "${ACNG_SUM_BEFORE}" ]]; then
  # apt-cacher-ng has no reload; the config is read at startup only.
  log "acng.conf changed, restarting apt-cache-ng"
  docker compose restart apt-cache-ng
else
  log "acng.conf unchanged"
fi

if [[ "$(acu_sum)" != "${ACU_SUM_BEFORE}" ]]; then
  # No reload here either: config and keyring are read at startup only.
  log "apt-cacher-ultra config or keys changed, restarting apt-cache"
  docker compose restart apt-cache
else
  log "apt-cacher-ultra config and keys unchanged"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
# Every site block is an HTTPS site, so port 80 carries nothing but Caddy's
# auto-HTTPS redirect -- and a request to 127.0.0.1 has a Host header matching
# no site block at all, which is answered by that same redirect server. Both
# facts mean a plain http://127.0.0.1 probe can only ever return 308.
# --resolve pins the real hostname at the loopback address, so this exercises
# the actual site block and its certificate without depending on the public DNS
# record pointing here yet.
local_url(){ echo "https://${BASE_DOMAIN}$1"; }
RESOLVE=(--resolve "${BASE_DOMAIN}:443:127.0.0.1")

log "Waiting for Caddy"
for _ in $(seq 1 30); do
  curl -fsS --max-time 5 "${RESOLVE[@]}" "$(local_url /healthz)" >/dev/null 2>&1 && break
  sleep 2
done

failed=0
check(){ # label, expected-codes-regex, url, curl args...
  local label="$1" want="$2" url="$3"; shift 3
  local code
  # `local code` and the assignment are separate statements, so the assignment
  # carries curl's exit status -- and under `set -e` a connection refused (7)
  # killed the whole run mid-table, silently, reporting nothing about the checks
  # that never got to run. A probe that cannot connect is a result, not a reason
  # to stop: record it as 000 and carry on through the rest of the table.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 45 "$@" "${url}" 2>/dev/null)" \
    || code="000"
  if [[ "${code}" =~ ${want} ]]; then printf '  ok    %-30s %s\n' "${label}" "${code}"
  elif [[ "${code}" == "000" ]]; then
    printf '  FAIL  %-30s no connection  (%s)\n' "${label}" "${url}"; failed=$((failed + 1))
  else printf '  FAIL  %-30s %s  (%s)\n' "${label}" "${code}" "${url}"; failed=$((failed + 1)); fi
}

# The registry binds its port a moment after the container reports started, so a
# check that runs immediately races it. Waiting here rather than lengthening
# every probe keeps a genuine failure fast to report.
log "Waiting for the registries"
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r name _ port _ <<<"${entry}"
  for _ in $(seq 1 20); do
    curl -fsS --max-time 3 "http://127.0.0.1:${port}/v2/" >/dev/null 2>&1 && break
    sleep 1
  done
done

echo
log "Local checks"
check "healthz" '^200$' "$(local_url /healthz)" "${RESOLVE[@]}"
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r name _ port _ <<<"${entry}"
  check "registry ${name} /v2/" '^(200|401)$' "http://127.0.0.1:${port}/v2/"
done

echo
log "Public checks over TLS"
check "apt  ubuntu-noble" '^200$' "https://${BASE_DOMAIN}/repository/ubuntu-noble/dists/noble/InRelease"
check "apt  debian-trixie" '^200$' "https://${BASE_DOMAIN}/repository/debian-trixie/dists/trixie/InRelease"
check "apt  docker-ubuntu-noble" '^200$' "https://${BASE_DOMAIN}/repository/docker-ubuntu-noble/dists/noble/InRelease"
check "apt  helm-apt" '^200$' "https://${BASE_DOMAIN}/repository/helm-apt/dists/any/InRelease"
check "apt  kubernetes-v1-34" '^200$' "https://${BASE_DOMAIN}/repository/kubernetes-v1-34/Release"
check "helm helm-tigera" '^200$' "https://${BASE_DOMAIN}/repository/helm-tigera/index.yaml"
check "helm helm-metrics-server" '^200$' "https://${BASE_DOMAIN}/repository/helm-metrics-server/index.yaml"
# The chart URLs in an index must point back here, not at GitHub. A Helm client
# reads this field and downloads from whatever it says, so if the rewrite stops
# working every `helm install` silently leaves the mirror again.
#
# Fetched and asserted separately, and retried. The first version of this check
# piped `curl -fsS` straight into grep, so a 502 from Caddy while content-cache
# was still starting reported itself as "chart urls still point upstream" -- a
# confident, specific and entirely wrong diagnosis of a connection failure. It
# failed a deploy that way once.
helm_index=""
for _ in $(seq 1 15); do
  if helm_index="$(curl -fsS --max-time 60 \
       "https://${BASE_DOMAIN}/repository/helm-tigera/index.yaml" 2>/dev/null)"; then
    [[ -n "${helm_index}" ]] && break
  fi
  helm_index=""
  sleep 2
done
if [[ -z "${helm_index}" ]]; then
  printf '  FAIL  %-30s could not fetch the index at all\n' "helm url rewrite"
  failed=$((failed + 1))
elif grep -qE "^[[:space:]]+- https://${BASE_DOMAIN}/repository/" <<<"${helm_index}"; then
  printf '  ok    %-30s chart urls point here\n' "helm url rewrite"
else
  printf '  FAIL  %-30s index served, but chart urls still point upstream\n' "helm url rewrite"
  failed=$((failed + 1))
fi

check "raw  raw-docker gpg" '^200$' "https://${BASE_DOMAIN}/repository/raw-docker/linux/ubuntu/gpg"
check "raw  raw-k8s" '^200$' "https://${BASE_DOMAIN}/repository/raw-k8s/release/stable.txt"
check "raw  raw-helm checksum" '^200$' "https://${BASE_DOMAIN}/repository/raw-helm/helm-v3.16.0-linux-amd64.tar.gz.sha256sum"

# The three redirect paths. These answer 302 by design -- see REDIRECTS ARE
# PASSED THROUGH above -- so asserting on the immediate status code would fail a
# working mirror, which is exactly what it did on the first eu-central cutover.
# -L follows to the CDN and asserts the thing that actually matters: a client
# can get the bytes. Every probe here is a few KB, deliberately -- a smoke test
# should not pull a 30MB release tarball on every run.
check "raw  raw-pkgs-k8s key" '^200$' "https://${BASE_DOMAIN}/repository/raw-pkgs-k8s/core:/stable:/v1.34/deb/Release.key" -L
check "raw  raw-buildkite gpgkey" '^200$' "https://${BASE_DOMAIN}/repository/raw-buildkite-helm/gpgkey" -L
check "raw  raw-github release" '^200$' "https://${BASE_DOMAIN}/repository/raw-github/derailed/k9s/releases/download/v0.32.5/checksums.sha256" -L
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r _ sub _ _ <<<"${entry}"
  check "registry ${sub} TLS" '^(200|401)$' "https://${sub}.${BASE_DOMAIN}/v2/"
done

echo
if [[ "${failed}" -ne 0 ]]; then
  cat >&2 <<EOF
${failed} check(s) failed.

Read this before rolling back. These are assertions about a stack that is
already running, and an assertion can be wrong -- a check that fails while the
rest of the table passes is far more likely to be a bad expectation than a
broken mirror. Confirm the thing the check claims is broken really is:

  curl -sI --resolve ${BASE_DOMAIN}:443:127.0.0.1 https://${BASE_DOMAIN}/healthz
  cd ${STACK_DIR} && docker compose ps && docker compose logs --tail 50

Roll back only if the mirror is genuinely not serving. Nexus is stopped but
intact:

  cd ${STACK_DIR} && docker compose down
  cd ${OLD_STACK_DIR} && docker compose up -d

Nothing under /opt/nexus or ${OLD_STACK_DIR} was deleted, and the wildcard is in
both stacks' certs/ directories.
EOF
  exit 1
fi

cat <<EOF

Done on ${BASE_DOMAIN}.

  ${#APT_REPOS[@]} apt-cacher-ultra ${ACU_VERSION} routes, ${#APT_FLAT_REPOS[@]} apt-cacher-ng Remap entries,
  7 registry containers (${REGISTRY_IMAGE%@*}),
  10 Caddy routes. No licence meter, no admin user, no EULA, no realm.

EOF

if [[ -d "${OLD_STACK_DIR}" ]]; then
  cat <<EOF
Nexus is STOPPED, NOT DELETED. Roll back at any time with:

  cd ${STACK_DIR} && docker compose down
  cd ${OLD_STACK_DIR} && docker compose up -d

Once you are satisfied -- give it a few days of real traffic -- reclaim the disk:

  rm -rf /opt/nexus ${OLD_STACK_DIR}

EOF
fi

cat <<EOF
The caches start cold. That is expected and self-correcting; the first pull of
anything is a miss and every one after it is not.
EOF
