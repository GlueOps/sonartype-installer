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
#   27 apt suites       -> nginx (apt-nginx), 6 upstream hosts
#    7 registries       -> ghcr.io/glueops/registry in pull-through mode, one per
#                          upstream (see REGISTRY_IMAGE)
#    4 helm + 6 raw     -> nginx cache behind Caddy
# No licence meter, no admin user, no EULA, no realm to switch on by hand.
#
# Every cache is plain local disk. Upstream is explicit that a pull-through
# registry cache uses the filesystem storage driver; apt, helm and raw cache in
# nginx:alpine, so Caddy stays the stock caddy:2 image.
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
#   NGINX_IMAGE         nginx image for apt-nginx and content-cache, tag@digest
#   APT_CACHE_MAX_SIZE  apt package cache ceiling, default 40g
#   APT_CACHE_MIN_FREE  free disk the apt cache always leaves, default 10g
#   LOG_MAX_SIZE        per-container log file size before rotation, default 50m
#   LOG_MAX_FILES       rotated log files kept per container, default 5
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

# apt-nginx and content-cache. Pinned: the apt config is tested against this
# version, and `resolve` in upstream blocks needs 1.27.3+.
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.31.6-alpine@sha256:d10753d9289b8e3f884386351f73554ce72b631378949deddd75e83ee296c427}"
# The apt package cache. min_free is what keeps it from filling a disk the
# registries share: nginx evicts rather than write past it.
APT_CACHE_MAX_SIZE="${APT_CACHE_MAX_SIZE:-40g}"
APT_CACHE_MIN_FREE="${APT_CACHE_MIN_FREE:-10g}"
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
for v in APT_CACHE_MAX_SIZE APT_CACHE_MIN_FREE; do
  [[ "${!v}" =~ ^[0-9]+[kKmMgG]$ ]] || die "${v}=${!v}: expected a number and a unit, e.g. 40g"
done

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

# name|upstream host|upstream base path -- served by apt-nginx over https.
#
# Prefixes that share a host and base share one cache: the nine ubuntu-*
# repositories have one pool/, so a .deb fetched through one is a hit through
# the others. debian-security is a separate archive with its own pool/.
# kubernetes goes to prod-cdn.packages.k8s.io directly with literal colons:
# pkgs.k8s.io only redirects there, and CloudFront keys its cache on the exact
# spelling -- a percent-encoded %3a path was served month-old indexes.
# packages.buildkite.com answers every path with a 302 to signed CloudFront.
APT_REPOS=(
  "ubuntu-jammy|archive.ubuntu.com|/ubuntu"
  "ubuntu-jammy-updates|archive.ubuntu.com|/ubuntu"
  "ubuntu-jammy-security|archive.ubuntu.com|/ubuntu"
  "ubuntu-noble|archive.ubuntu.com|/ubuntu"
  "ubuntu-noble-updates|archive.ubuntu.com|/ubuntu"
  "ubuntu-noble-security|archive.ubuntu.com|/ubuntu"
  "ubuntu-resolute|archive.ubuntu.com|/ubuntu"
  "ubuntu-resolute-updates|archive.ubuntu.com|/ubuntu"
  "ubuntu-resolute-security|archive.ubuntu.com|/ubuntu"
  "debian-bookworm|deb.debian.org|/debian"
  "debian-bookworm-updates|deb.debian.org|/debian"
  "debian-bookworm-security|security.debian.org|/debian-security"
  "debian-trixie|deb.debian.org|/debian"
  "debian-trixie-updates|deb.debian.org|/debian"
  "debian-trixie-security|security.debian.org|/debian-security"
  "kubernetes-v1-32|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.32/deb"
  "kubernetes-v1-33|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.33/deb"
  "kubernetes-v1-34|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.34/deb"
  "kubernetes-v1-35|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.35/deb"
  "kubernetes-v1-36|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.36/deb"
  "kubernetes-v1-37|prod-cdn.packages.k8s.io|/repositories/isv:/kubernetes:/core:/stable:/v1.37/deb"
  "docker-ubuntu-jammy|download.docker.com|/linux/ubuntu"
  "docker-ubuntu-noble|download.docker.com|/linux/ubuntu"
  "docker-ubuntu-resolute|download.docker.com|/linux/ubuntu"
  "docker-debian-bookworm|download.docker.com|/linux/debian"
  "docker-debian-trixie|download.docker.com|/linux/debian"
  "helm-apt|packages.buildkite.com|/helm-linux/helm-debian/any"
)

# The route names, and each distinct upstream host once.
apt_names=(); apt_hosts=()
for entry in "${APT_REPOS[@]}"; do
  IFS='|' read -r name host _ <<<"${entry}"
  apt_names+=("${name}")
  [[ " ${apt_hosts[*]} " == *" ${host} "* ]] || apt_hosts+=("${host}")
done

# name:upstream host:upstream path prefix
# Helm chart repositories: an index.yaml plus .tgz files over plain HTTPS.
HELM_REPOS=(
  "helm-stable:charts.helm.sh:/stable"
  "helm-tigera:docs.tigera.io:/calico/charts"
  "helm-metrics-server:kubernetes-sigs.github.io:/metrics-server"
  "helm-containeroo:charts.containeroo.ch:"
)

# Raw HTTP proxies. Nexus ran these with contentMaxAge=0; nginx matches that by
# checking upstream on every request and serving its cached copy if that fails.
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
# proxies to $upstream_http_location, up to nginx's 10-hop cap (500 beyond).
# The cache key stays the ORIGINAL request path, not the redirect target: buildkite's CloudFront URLs are signed and
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

# A host with no room left fails deep inside an image pull or a cache write,
# with an error that reads like anything but a full disk. Check first and say so.
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

Pulling the images alone needs a few hundred MB, and a registry cache only
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
mkdir -p "${STACK_DIR}"/{certs,caddy-data,caddy-config,apt-nginx-cache,registries,content-cache,content-log}
mkdir -p "${STACK_DIR}/site"
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r name _ _ _ <<<"${entry}"
  mkdir -p "${STACK_DIR}/registries/${name}"
done

if [[ "${DRY_RUN}" != "1" ]]; then
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
# apt-nginx: the apt cache
# ---------------------------------------------------------------------------
# Quoted heredocs, so every nginx $variable stays literal; only the table rows
# and the two sizes are generated, with constant printf formats.
log "Writing apt-nginx.conf"
{
  cat <<'NGINX'
# apt-nginx: the apt cache for the /repository/<name>/ prefixes in APT_REPOS.
# Two tiers: :3142 caches (keys, slices, locks, stale); 127.0.0.1:8091 fetches
# (DNS, TLS, redirects) and never caches. slice and redirect-following must never
# share a tier: a slice subrequest that follows a redirect loses its Range and
# splices a whole body into the file.

worker_processes auto;
worker_rlimit_nofile 65536;            # slice 1m holds one fd per MB in flight; short = truncated 200s
error_log /dev/stderr warn;
pid /run/nginx.pid;

events { worker_connections 8192; }

http {
    default_type application/octet-stream;
    sendfile on;
    server_tokens off;

    log_format apt   '$time_iso8601 $status $upstream_cache_status [$upstream_status] '
                     '[$upstream_response_time] $body_bytes_sent/$sent_http_content_length '
                     '$request_time $request_method $request_uri "$http_user_agent"';
    log_format fetch 'fetch $status [$upstream_status] [$upstream_addr] [$upstream_connect_time] '
                     '[$upstream_response_time] $body_bytes_sent $request_time $request_uri';

    # Docker DNS, IPv4 only: the compose network has no IPv6 route.
    resolver 127.0.0.11 ipv6=off valid=30s;
    resolver_timeout 5s;

    proxy_http_version 1.1;
    proxy_buffer_size 32k;             # Buildkite's signed Location header does not fit in 4k
    proxy_buffers 8 32k;
    proxy_busy_buffers_size 64k;
    proxy_max_temp_file_size 2048m;    # never 0: that silently stops caching anything > buffers

    # Separate zones so package churn can never evict the indexes outages depend on.
    # No min_free on idx: pool fills would otherwise evict every index under disk pressure.
    proxy_cache_path /var/cache/apt-nginx/idx  levels=1:2 keys_zone=apt_idx:32m
                     max_size=10g inactive=45d use_temp_path=off;
NGINX
  printf '    proxy_cache_path /var/cache/apt-nginx/pool levels=1:2 keys_zone=apt_pool:256m\n'
  printf '                     max_size=%s min_free=%s inactive=45d\n' "${APT_CACHE_MAX_SIZE}" "${APT_CACHE_MIN_FREE}"
  printf '                     loader_files=1000 loader_threshold=300ms use_temp_path=off;\n'
  cat <<'NGINX'


    # ---------------- request validation ----------------
    # GET/HEAD without a body: a body would be forwarded upstream.
    map $request_method$http_content_length$http_transfer_encoding $apt_bad_method { default 1; GET 0; HEAD 0; }

    # Allow-list on the raw path. apt 2.4-3.2 escapes ~ and + (%7e, %2b); no other escape is
    # allowed, so the key ($uri) and upstream path ($request_uri) name the same object.
    # No query, no dot or empty segments.
    map $request_uri $apt_bad {
        default 1;
        "/healthz" 0;
        ~/\.\.?(?:/|$) 1;
        "~^/repository/[a-z0-9-]+(?:/(?:[A-Za-z0-9._~+:@-]|%7[Ee]|%2[Bb])+)+/?$" 0;
    }

    # ---------------- repo table, from APT_REPOS ----------------
    map $uri $apt_origin {
        default "";
NGINX
  for entry in "${APT_REPOS[@]}"; do
    IFS='|' read -r name host base <<<"${entry}"
    printf '        ~^/repository/%-28s %s%s;\n' "${name}/" "${host}" "${base}"
  done
  cat <<'NGINX'
    }
    # Upstream path is raw (apt's %7e must reach the CDN as sent); the key path is decoded,
    # so %7e and ~ share one entry. The key never includes $host or the client prefix.
    map $request_uri $apt_path     { ~^/repository/[^/?]+(?<apt_p>/[^?]*)  $apt_p; }
    map $uri         $apt_key_path { ~^/repository/[^/]+(?<apt_kp>/.*)$    $apt_kp; }

    # Captive portals, error pages, empty bodies. volatile: re-evaluated per slice subrequest.
    map $upstream_http_content_type $apt_nocache { volatile; default 0; ~*^text/html 1; }
    map $upstream_http_content_length $apt_empty { volatile; default 0; "0" 1; }

    upstream apt_fetch { zone apt_fetch 64k; server 127.0.0.1:8091; keepalive 32; }

    # ================= cache tier. No error_page here: it would break slice. =================
    server {
        listen 3142;
        access_log /dev/stdout apt;

        proxy_connect_timeout 5s;
        proxy_read_timeout 50s;            # > fetch worst case: 25s of attempts + 3s connect + 20s read
        proxy_next_upstream off;           # loopback: nothing to retry
        proxy_pass_request_headers off;    # nothing from the client reaches an upstream
        proxy_hide_header Set-Cookie;

        if ($apt_bad_method) { return 405; }
        if ($apt_bad)        { return 400; }

        location = /healthz { return 200 "ok\n"; }

        # 1. Pool: packages and anything under pool/. Immutable, sliced, shared across prefixes.
        location ~ (?:^/repository/[^/]+/(?:.+/)?pool/|\.(?:deb|udeb|ddeb)$) {
            if ($apt_origin = "") { return 404; }
            slice 1m;
            proxy_cache apt_pool;
            proxy_cache_key "$apt_origin$apt_key_path$slice_range";
            # a location-level proxy_set_header replaces the whole inherited list: repeat all
            proxy_set_header Range $slice_range;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_ignore_headers Cache-Control Expires Set-Cookie Vary X-Accel-Expires
                                 X-Accel-Redirect X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset;
            proxy_hide_header Set-Cookie;
            proxy_hide_header ETag;            # else slice pins slice 0's ETag: one upstream ETag change breaks the file for good
            proxy_hide_header Last-Modified;   # no If-Range match: a resume after a failed fill restarts from byte 0
            proxy_cache_valid 200 206 3650d;   # retention is inactive=/max_size
            proxy_cache_lock on;
            proxy_cache_lock_age 25s;          # < apt's 30s timeout: waiters on a dead worker's lock recover in time
            keepalive_timeout 0;               # nginx bug: a failed slice mid-body is not an error; close so apt sees one
            proxy_ignore_client_abort on;      # a fill whose client left is still cached, not discarded
            proxy_cache_lock_timeout 1h;       # waiters never bypass the cache
            proxy_cache_background_update off;
            proxy_cache_use_stale error timeout invalid_header updating
                                  http_500 http_502 http_503 http_504;
            proxy_no_cache $apt_nocache $apt_empty;
            proxy_pass http://apt_fetch/$apt_origin$apt_path;
        }

        # 2. Immutable indexes: by-hash and pdiff patches. Sliced like the pool, so lock waiters
        #    on a large index (~20 MB Ubuntu Packages) get bytes before apt's 30s timeout.
        location ~ (?:^/repository/[^/]+/dists/.+/by-hash/|^/repository/[^/]+/dists/.+\.diff/T-[^/]+$) {
            if ($apt_origin = "") { return 404; }
            slice 1m;
            proxy_cache apt_idx;
            proxy_cache_key "$apt_origin$apt_key_path$slice_range";
            proxy_set_header Range $slice_range;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_ignore_headers Cache-Control Expires Set-Cookie Vary X-Accel-Expires
                                 X-Accel-Redirect X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset;
            proxy_hide_header Set-Cookie;
            proxy_hide_header ETag;
            proxy_hide_header Last-Modified;
            proxy_cache_valid 200 206 3650d;
            proxy_cache_lock on;
            proxy_cache_lock_age 25s;
            proxy_cache_lock_timeout 120s;
            keepalive_timeout 0;
            proxy_ignore_client_abort on;      # a fill whose client left is still cached, not discarded
            proxy_cache_background_update off;
            proxy_cache_use_stale error timeout invalid_header updating
                                  http_500 http_502 http_503 http_504;
            proxy_no_cache $apt_nocache $apt_empty;
            proxy_pass http://apt_fetch/$apt_origin$apt_path;
        }

        # 3. Mutable indexes: dists/ and the flat (k8s) index names. 1s + revalidate keeps
        #    InRelease and Packages from different publishes apart. Never `updating`: it serves
        #    the old InRelease while the new Packages is already cached.
        #    Index names only: installer images under dists/ fall through to the 404.
        location ~ (?:^/repository/[^/]+/dists/(?:.+/)?(?:InRelease|Release(?:\.gpg)?|Index|(?:Packages|Sources|Translation-[^/]+|Contents-[^/]+|Components-[^/]+|icons-[^/]+|Commands-[^/]+|CID-Index-[^/]+)(?:\.[A-Za-z0-9]+)*)$|^/repository/[^/]+/(?:InRelease|Release|Release\.gpg|Packages(?:\.(?:gz|xz|bz2|lzma|zst))?)$) {
            if ($apt_origin = "") { return 404; }
            proxy_cache apt_idx;
            proxy_cache_key "$apt_origin$apt_key_path";
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_ignore_headers Cache-Control Expires Set-Cookie Vary X-Accel-Expires
                                 X-Accel-Redirect X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset;
            proxy_cache_valid 200 1s;          # must stay > 0: 0 means "do not cache"
            proxy_cache_revalidate on;         # a refresh is a conditional GET, usually a 304
            proxy_set_header If-None-Match "";  # date-only revalidation: a lagging mirror's older copy answers 304, never replaces a newer one
            proxy_cache_lock on;               # collapses cold misses only, not refreshes
            proxy_cache_lock_age 10s;
            proxy_cache_lock_timeout 15s;
            proxy_cache_background_update off;
            proxy_read_timeout 15s;            # stale well inside apt's 30s timeout
            proxy_cache_use_stale error timeout invalid_header
                                  http_500 http_502 http_503 http_504 http_403 http_429;
            proxy_no_cache $apt_nocache $apt_empty;
            proxy_pass http://apt_fetch/idx/$apt_origin$apt_path;
        }

        # 4. Anything else (ls-lR.gz, installer images, unknown repos): refused.
        location / { return 404; }
    }

    # ================= fetch tier: DNS, TLS, keepalive, redirects. Never caches. =================
    map $request_uri $fetch_host { ~^/(?:idx/)?(?<fh>[^/?]+)/       $fh; }
    map $request_uri $fetch_path { ~^/(?:idx/)?[^/?]+(?<fp>/[^?]*)  $fp; }
    map $fetch_host $fetch_scheme {    # allow-list: the distinct APT hosts, nothing else
        default "";
NGINX
  for host in "${apt_hosts[@]}"; do printf '        %-25s https;\n' "${host}"; done
  cat <<'NGINX'
    }

    # Each group is named exactly after its host: the group name is the SNI and verify name.
    # max_fails=1 fail_timeout=10s skips a dead address for 10s; no effect on a single-address host.
    # keepalive_timeout 4s: below Apache's 5s idle close; a silently dropped pooled connection costs 20s.
NGINX
  for i in "${!apt_hosts[@]}"; do
    printf '    upstream %s { zone apt_up_%d 64k; server %s:443 resolve max_fails=1 fail_timeout=10s; keepalive 16; keepalive_timeout 4s; }\n' \
      "${apt_hosts[$i]}" "${i}" "${apt_hosts[$i]}"
  done
  cat <<'NGINX'


    server {
        listen 127.0.0.1:8091;
        access_log /dev/stdout fetch;
        recursive_error_pages on;          # hop 2+; nginx caps the chain at 10 (500)

        proxy_ssl_server_name on;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 4;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_connect_timeout 3s;
        proxy_read_timeout 20s;            # < next_upstream_timeout; also the longest mid-body stall a fill survives
        proxy_next_upstream error timeout; # across the resolved addresses; no _tries cap
        proxy_next_upstream_timeout 25s;
        proxy_buffering off;               # the cache tier buffers
        proxy_intercept_errors on;
        proxy_ignore_headers X-Accel-Redirect X-Accel-Expires X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset;
        error_page 301 302 303 307 308 = @apt_follow;

        # Packages, by-hash and pdiffs have immutable names, so a 404 from one upstream
        # address means that address is behind (archive.ubuntu.com's addresses drift
        # apart for hours): try the next one. apt retries neither a 404 nor a 5xx.
        location / {
            proxy_next_upstream error timeout http_404 http_500 http_502 http_503 http_504 http_429;
            if ($fetch_scheme = "") { return 403; }
            proxy_set_header Host $fetch_host;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_pass $fetch_scheme://$fetch_host$fetch_path;
        }

        location /idx/ {                   # mutable indexes: a stalled peer is cut in time for one retry inside the cache tier's 15s
            proxy_read_timeout 7s;
            error_page 301 302 303 307 308 = @apt_follow_idx;
            if ($fetch_scheme = "") { return 403; }
            proxy_set_header Host $fetch_host;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_pass $fetch_scheme://$fetch_host$fetch_path;
        }

        location @apt_follow {
            proxy_next_upstream error timeout http_404 http_500 http_502 http_503 http_504 http_429;
            # an `if`, not a map: a map is evaluated once per request, so hop 2+ would reuse hop 1's verdict
            if ($upstream_http_location !~ "^https://[a-z0-9]+\.cloudfront\.net/") { return 502; }
            set $apt_redirect $upstream_http_location;
            proxy_set_header Host $proxy_host;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_set_header Authorization "";
            proxy_pass $apt_redirect;
        }

        location @apt_follow_idx {
            proxy_read_timeout 7s;
            # an `if`, not a map: a map is evaluated once per request, so hop 2+ would reuse hop 1's verdict
            if ($upstream_http_location !~ "^https://[a-z0-9]+\.cloudfront\.net/") { return 502; }
            set $apt_redirect $upstream_http_location;
            proxy_set_header Host $proxy_host;
            proxy_set_header Connection "";
            proxy_set_header Accept-Encoding "";
            proxy_set_header Authorization "";
            proxy_pass $apt_redirect;
        }
    }
}
NGINX
} > "${STACK_DIR}/apt-nginx.conf"
! grep -qF '${' "${STACK_DIR}/apt-nginx.conf" || die "unrendered placeholder left in ${STACK_DIR}/apt-nginx.conf"


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
  echo "  # upstream_status lists every redirect hop, separated by \" : \"."
  echo "  log_format cache '\$status \$upstream_cache_status \$body_bytes_sent \$request_uri'"
  echo "                   ' [\$upstream_status] [\$upstream_bytes_received]';"
  echo "  access_log /var/log/nginx/access.log cache;"
  echo
  echo "  # Docker's embedded DNS, for the redirect targets and the upstream blocks"
  echo "  # below. ipv6=off: the compose network has no IPv6 route."
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
  echo "  proxy_ssl_server_name on;"
  echo "  proxy_ssl_protocols TLSv1.2 TLSv1.3;"
  echo "  proxy_http_version 1.1;"
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
  echo "  # X-Forwarded-* are stripped in Caddy (strip_forwarded)."
  echo

  # One upstream per host, named after it so proxy_pass https://<host>/ binds to
  # it unchanged. A plain proxy_pass resolves once at startup through musl,
  # which keeps AAAA records; resolve goes through the ipv6=off resolver instead.
  upstream_hosts=()
  for entry in "${HELM_REPOS[@]}" "${RAW_REPOS[@]}"; do
    IFS=: read -r _ host _ <<<"${entry}"
    [[ " ${upstream_hosts[*]} " == *" ${host} "* ]] || upstream_hosts+=("${host}")
  done
  for i in "${!upstream_hosts[@]}"; do
    echo "  upstream ${upstream_hosts[$i]} {"
    echo "    zone upstream_${i} 64k;"
    echo "    server ${upstream_hosts[$i]}:443 resolve;"
    echo "  }"
  done
  echo
  echo "  server {"
  echo "    listen 8080;"
  echo "    server_name _;"
  echo "    # Lets @follow_redirect handle hop 2 onward; nginx caps the chain at 10."
  echo "    recursive_error_pages on;"
  echo
  echo "    location = /healthz { return 200 \"ok\\n\"; }"
  echo

  # The outage behaviour this component exists for, shared by helm and raw:
  # serve what we have when the upstream fails, whatever its cache headers say.
  # $1: extra headers to ignore.
  cache_resilience() {
    echo "      proxy_ignore_headers Cache-Control Expires Set-Cookie X-Accel-Expires"
    echo "                           X-Accel-Redirect X-Accel-Limit-Rate X-Accel-Buffering X-Accel-Charset${1:+ $1};"
    echo "      proxy_hide_header Set-Cookie;"
    echo "      proxy_cache_use_stale error timeout invalid_header updating"
    echo "                            http_500 http_502 http_503 http_504 http_429 http_403 http_404;"
    echo "      proxy_connect_timeout 5s;"
    echo "      proxy_read_timeout 30s;"
    echo "      # Stops new attempts after 10s. No tries cap: if a host resolves to an"
    echo "      # unreachable address, a cap can end the request before a good one is tried."
    echo "      proxy_next_upstream_timeout 10s;"
  }

  # Helm settings, shared by the helm locations and @follow_redirect_helm: a
  # named location inherits nothing from the location that jumped to it.
  helm_policy() {
    echo "      proxy_cache content;"
    # Vary is safe to ignore only because Accept-Encoding is cleared below.
    cache_resilience Vary
    echo "      # An index moves; a chart tarball at a version does not."
    echo "      proxy_cache_valid 200 206 5m;"
    echo "      proxy_intercept_errors on;"
    echo "      error_page 301 302 303 307 308 = @follow_redirect_helm;"
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
  }

  # Raw settings, shared by the raw locations and @follow_redirect.
  raw_policy() {
    echo "      proxy_cache content;"
    cache_resilience
    echo "      # Must stay above 0: 0 means \"do not cache\"."
    echo "      proxy_cache_valid 200 206 1s;"
    echo "      # The client waits for the check, so a hung upstream delays it up to 30s."
    echo "      proxy_cache_background_update off;"
    echo "      proxy_intercept_errors on;"
    echo "      error_page 301 302 303 307 308 = @follow_redirect;"
  }

  # ---- helm: cache, and rewrite the chart URLs in index.yaml ----
  for entry in "${HELM_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "    location /repository/${name}/ {"
    echo "      proxy_pass https://${host}${path}/;"
    echo "      proxy_set_header Host ${host};"
    helm_policy
    echo "    }"
    echo
  done

  # ---- raw: cache, and follow redirects rather than handing them back ----
  for entry in "${RAW_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "    location /repository/${name}/ {"
    echo "      proxy_pass https://${host}${path}/;"
    echo "      proxy_set_header Host ${host};"
    raw_policy
    echo "    }"
    echo
  done

  # $upstream_http_location is the Location header of the response just
  # intercepted; the http-level cache key keeps the result under the original path.
  for handler in follow_redirect follow_redirect_helm; do
    echo "    location @${handler} {"
    echo "      internal;"
    echo "      set \$redirect_target \$upstream_http_location;"
    echo "      proxy_pass \$redirect_target;"
    echo "      proxy_set_header Host \$proxy_host;"
    echo "      proxy_set_header Authorization \"\";"
    if [[ "${handler}" == "follow_redirect_helm" ]]; then helm_policy; else raw_policy; fi
    echo "    }"
    echo
  done
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
  echo "<!doctype html><meta charset=utf-8><title>${BASE_DOMAIN} mirror</title>"
  echo "<style>body{font:14px/1.5 system-ui,sans-serif;max-width:52rem;margin:3rem auto;padding:0 1rem}"
  echo "code{background:#f4f4f5;padding:.1em .35em;border-radius:3px}h2{margin-top:2rem;font-size:1rem}</style>"
  echo "<h1>${BASE_DOMAIN}</h1><p>Pull-through mirror. Nothing here is a source of truth; every path proxies an upstream.</p>"
  echo "<h2>Container registries</h2><ul>"
  for entry in "${REGISTRIES[@]}"; do
    IFS=: read -r _ sub _ up <<<"${entry}"
    echo "<li><code>${sub}.${BASE_DOMAIN}</code> &rarr; ${up}</li>"
  done
  echo "</ul><h2>APT (${#APT_REPOS[@]})</h2><ul>"
  for entry in "${APT_REPOS[@]}"; do
    IFS='|' read -r name host base <<<"${entry}"
    echo "<li><code>/repository/${name}/</code> &rarr; https://${host}${base}</li>"
  done
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

# Caddy adds X-Forwarded-For / -Proto / -Host to every proxied request. That is
# right for a backend you own and wrong for a third-party origin: these are
# public CDNs being fetched as an ordinary client, which is what Nexus did.
# packages.buildkite.com is the proof -- it answers a request carrying
# X-Forwarded-Host with a 301 to its marketing site instead of the signed CDN
# URL for the key. Strip them here: content-cache forwards client headers
# upstream (apt-nginx does not, but gets the same treatment).
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

# Build the apt route matcher from the table above, so the Caddyfile and
# apt-nginx.conf cannot drift apart silently.
apt_alternation="$(IFS='|'; echo "${apt_names[*]}")"

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
  echo "  # ---- APT: ${#APT_REPOS[@]} repositories ----"
  echo "  @apt path_regexp ^/repository/(${apt_alternation})(/|\$)"
  echo "  handle @apt {"
  echo "    reverse_proxy apt-nginx:3142 {"
  echo "      header_up Host {host}"
  strip_forwarded
  # A killed nginx worker drops the connection, and Caddy's own 502 has no
  # body, which apt treats as final. Caddy retries only when no response
  # headers came back, so a download is never duplicated or spliced.
  echo "      lb_retries 2"
  echo "      lb_try_interval 250ms"
  echo "    }"
  echo "  }"
  echo

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
  strip_forwarded
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
# nginx cannot reload a changed cache zone (path, levels=, keys_zone): it keeps
# the old config and logs [emerg]. A label carrying a hash of those lines makes
# compose recreate the container when they change; everything else is reloaded.
cache_zones_label() {
  echo "    labels:"
  echo "      - mirror.cache-zones=$(awk '/^[[:space:]]*proxy_cache_path/,/;/' "$1" | sha256sum | cut -c1-16)"
}
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
  # apt-nginx closes its connection after every sliced response (see
  # apt-nginx.conf), which leaves Caddy's side in TIME_WAIT. Without reuse, one
  # fast client can exhaust Caddy's ephemeral ports and every apt request 502s.
  echo "    sysctls:"
  echo "      - net.ipv4.tcp_tw_reuse=1"
  echo "    depends_on:"
  echo "      - apt-nginx"
  echo "      - content-cache"
  echo
  echo "  content-cache:"
  echo "    image: ${NGINX_IMAGE}"
  echo "    container_name: content-cache"
  echo "    restart: unless-stopped"
  cache_zones_label "${STACK_DIR}/nginx.conf"
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
  echo "  apt-nginx:"
  echo "    image: ${NGINX_IMAGE}"
  echo "    container_name: apt-nginx"
  echo "    restart: unless-stopped"
  cache_zones_label "${STACK_DIR}/apt-nginx.conf"
  compose_logging
  echo "    # One file descriptor per 1 MB slice in flight; the default runs out under"
  echo "    # a cold bootstrap wave and nginx then truncates responses."
  echo "    ulimits:"
  echo "      nofile:"
  echo "        soft: 65536"
  echo "        hard: 65536"
  echo "    volumes:"
  echo "      - ${STACK_DIR}/apt-nginx.conf:/etc/nginx/nginx.conf:ro"
  echo "      - ${STACK_DIR}/apt-nginx-cache:/var/cache/apt-nginx"
  echo "    healthcheck:"
  echo "      test: [\"CMD-SHELL\", \"wget -qO- http://127.0.0.1:3142/healthz >/dev/null || exit 1\"]"
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
# compose resolves the project from the working directory.
cd "${STACK_DIR}"

# Pull before stopping anything: a failed pull with Nexus already down is an
# outage for no reason.
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
# answering, which makes a stale route look healthy. On a host that ran
# apt-cacher-ng this is also what removes its container; its cache in
# apt-cache/ is left on disk.
docker compose up -d --remove-orphans || die "could not start the stack; apt may be unavailable until a run succeeds -- check: docker compose -f ${STACK_DIR}/docker-compose.yml ps"

# compose does not notice a changed bind-mounted file, so every config is
# applied explicitly, on every run: a run that died after writing one must not
# leave the old one serving on the next.
#
# --force because Caddy skips a reload it judges unchanged, and the certificate
# files it points at can change without the Caddyfile doing so. Caddy may have
# just been (re)created, and its admin API takes a moment to listen.
log "Reloading Caddy"
for _ in $(seq 1 10); do
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force >/dev/null 2>&1 && break
  sleep 1
done
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --force \
  || die "Caddy would not load the new config -- check: docker compose -f ${STACK_DIR}/docker-compose.yml logs caddy"

# Reloaded every run, not on checksum change: a run that died after writing a
# config would otherwise leave the old one serving. A just-started nginx has no
# pid file yet, and reloading then fails.
for svc in apt-nginx content-cache; do
  log "Reloading ${svc}"
  for _ in $(seq 1 30); do
    docker compose exec -T "${svc}" test -s /run/nginx.pid && break
    sleep 1
  done
  docker compose exec -T "${svc}" sh -c 'nginx -t && nginx -s reload' \
    || die "${svc} would not load its config -- check: docker compose -f ${STACK_DIR}/docker-compose.yml logs ${svc}"
done

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

# Check keys by content: a redirect to an HTML page also returns 200.
check_pgp(){ # label, url
  local label="$1" url="$2" body
  body="$(curl -fsS --max-time 45 "${url}" 2>/dev/null)" || body=""
  if [[ "${body}" == "-----BEGIN PGP"* ]]; then printf '  ok    %-30s pgp key\n' "${label}"
  else printf '  FAIL  %-30s not a pgp key  (%s)\n' "${label}" "${url}"; failed=$((failed + 1)); fi
}

check_pgp "raw  raw-docker gpg" "https://${BASE_DOMAIN}/repository/raw-docker/linux/ubuntu/gpg"
check "raw  raw-k8s" '^200$' "https://${BASE_DOMAIN}/repository/raw-k8s/release/stable.txt"
check "raw  raw-helm checksum" '^200$' "https://${BASE_DOMAIN}/repository/raw-helm/helm-v3.16.0-linux-amd64.tar.gz.sha256sum"

# The three redirect paths. nginx follows the redirect itself, so the mirror must
# answer 200 -- no -L, which would let curl follow a redirect nginx should have.
# Every probe is a few KB; a smoke test should not pull a release tarball.
check "raw  raw-pkgs-k8s key" '^200$' "https://${BASE_DOMAIN}/repository/raw-pkgs-k8s/core:/stable:/v1.34/deb/Release.key"
check_pgp "raw  raw-buildkite gpgkey" "https://${BASE_DOMAIN}/repository/raw-buildkite-helm/gpgkey"
check "raw  raw-github release" '^200$' "https://${BASE_DOMAIN}/repository/raw-github/derailed/k9s/releases/download/v0.32.5/checksums.sha256"
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

  ${#APT_REPOS[@]} apt repositories via apt-nginx, 7 registry containers (${REGISTRY_IMAGE%@*}),
  ${#HELM_REPOS[@]} helm + ${#RAW_REPOS[@]} raw via nginx.
  No licence meter, no admin user, no EULA, no realm.

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
anything is a miss; after that raw paths revalidate and fall back to the cache.
EOF
