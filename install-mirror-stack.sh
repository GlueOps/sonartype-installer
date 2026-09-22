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
#   27 apt suites       -> apt-cacher-ng, 12 Remap entries
#    7 registries       -> ghcr.io/glueops/registry in pull-through mode, one per
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
#   CADDY_IMAGE         caddy image, tag@digest
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

ACNG_UID="${ACNG_UID:-8142}"

# Upstream Distribution 3.1.1 plus one fix so it can proxy public.ecr.aws, which
# stock registry:2/registry:3 cannot (distribution#4383): ECR Public answers HEAD
# on a blob with 401, and the proxy HEADs every blob before fetching it.
# https://github.com/GlueOps/registry
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.11.4@sha256:14a9c00d4e833ebc2b65d36515b37bde3b73f0b323a2663aaafc88953d8c4e3f}"

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

# Everything apt-cacher-ng answers for. The Remap table inside acng.conf is what
# maps these onto upstreams; Caddy only needs to know the set, to route it.
APT_REPOS=(
  ubuntu-jammy ubuntu-jammy-updates ubuntu-jammy-security
  ubuntu-noble ubuntu-noble-updates ubuntu-noble-security
  ubuntu-resolute ubuntu-resolute-updates ubuntu-resolute-security
  debian-bookworm debian-bookworm-updates debian-bookworm-security
  debian-trixie debian-trixie-updates debian-trixie-security
  kubernetes-v1-32 kubernetes-v1-33 kubernetes-v1-34
  kubernetes-v1-35 kubernetes-v1-36 kubernetes-v1-37
  docker-ubuntu-jammy docker-ubuntu-noble docker-ubuntu-resolute
  docker-debian-bookworm docker-debian-trixie
  helm-apt
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

# REDIRECTS ARE PASSED THROUGH, NOT FOLLOWED
# Nexus followed an upstream redirect server-side, so a client only ever talked
# to the mirror. Caddy does not follow them: it hands the 302 back and the client
# fetches the CDN itself. Three paths do this -- raw-github release assets,
# raw-pkgs-k8s Release.key, raw-buildkite-helm gpgkey.
#
# Rewriting the Location header back through the mirror was tried and removed.
# It cannot be made to hold:
#   - GitHub has already moved release assets from objects.githubusercontent.com
#     to release-assets.githubusercontent.com, so the hostname install.sh
#     documents is stale and a hardcoded list silently becomes a no-op.
#   - buildkite hands out a CloudFront URL whose signature covers the exact URL
#     and expires, on an opaque hostname free to change.
# A rewrite table that is wrong is worse than no rewrite table: it fails closed
# on a path that would otherwise have worked.
#
# The practical consequence is an egress one. These three fetches -- all of them
# small, all of them once per node bootstrap except github release assets -- need
# the client to reach the CDN. None of the raw repositories cached anything under
# Nexus either (they all ran contentMaxAge=0), so nothing else is lost.

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
# Caddyfile or acng.conf brings up nothing and silently leaves the old config
# serving. That has to be handled explicitly below, and it needs the old
# checksums taken before anything is rewritten.
cfg_sum() { [[ -f "$1" ]] && sha256sum "$1" | cut -d" " -f1 || echo "absent"; }
CADDY_SUM_BEFORE="$(cfg_sum "${STACK_DIR}/Caddyfile")"
ACNG_SUM_BEFORE="$(cfg_sum "${STACK_DIR}/acng.conf")"

log "Preparing ${STACK_DIR}"
mkdir -p "${STACK_DIR}"/{certs,caddy-data,caddy-config,apt-cache,apt-log,registries}
mkdir -p "${STACK_DIR}/site"
for entry in "${REGISTRIES[@]}"; do
  IFS=: read -r name _ _ _ <<<"${entry}"
  mkdir -p "${STACK_DIR}/registries/${name}"
done

if [[ "${DRY_RUN}" != "1" ]]; then
  chown -R "${ACNG_UID}:${ACNG_UID}" "${STACK_DIR}/apt-cache" "${STACK_DIR}/apt-log"

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
# apt-cacher-ng: same image and Remap table as deploy-apt-cache.sh
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

# Several local prefixes on one Remap share a cache tree. The nine ubuntu-*
# repositories differ only by the suite in the path and share an identical
# pool/, so they get one tree rather than nine copies of every .deb.
# archive.ubuntu.com carries every suite including -security.
Remap-ubuntu: /repository/ubuntu-jammy /repository/ubuntu-jammy-updates /repository/ubuntu-jammy-security /repository/ubuntu-noble /repository/ubuntu-noble-updates /repository/ubuntu-noble-security /repository/ubuntu-resolute /repository/ubuntu-resolute-updates /repository/ubuntu-resolute-security ; http://archive.ubuntu.com/ubuntu http://security.ubuntu.com/ubuntu

# debian-security is a genuinely separate archive with its own pool/, so unlike
# Ubuntu it does NOT merge with the main one.
Remap-debian: /repository/debian-bookworm /repository/debian-bookworm-updates /repository/debian-trixie /repository/debian-trixie-updates ; https://deb.debian.org/debian
Remap-debiansecurity: /repository/debian-bookworm-security /repository/debian-trixie-security ; https://security.debian.org/debian-security

# pkgs.k8s.io publishes each minor as an independent flat repository: no shared
# pool, so merging would be wrong.
Remap-k8s132: /repository/kubernetes-v1-32 ; https://pkgs.k8s.io/core:/stable:/v1.32/deb
Remap-k8s133: /repository/kubernetes-v1-33 ; https://pkgs.k8s.io/core:/stable:/v1.33/deb
Remap-k8s134: /repository/kubernetes-v1-34 ; https://pkgs.k8s.io/core:/stable:/v1.34/deb
Remap-k8s135: /repository/kubernetes-v1-35 ; https://pkgs.k8s.io/core:/stable:/v1.35/deb
Remap-k8s136: /repository/kubernetes-v1-36 ; https://pkgs.k8s.io/core:/stable:/v1.36/deb
Remap-k8s137: /repository/kubernetes-v1-37 ; https://pkgs.k8s.io/core:/stable:/v1.37/deb

# download.docker.com publishes linux/ubuntu and linux/debian as separate trees.
Remap-dockerubuntu: /repository/docker-ubuntu-jammy /repository/docker-ubuntu-noble /repository/docker-ubuntu-resolute ; https://download.docker.com/linux/ubuntu
Remap-dockerdebian: /repository/docker-debian-bookworm /repository/docker-debian-trixie ; https://download.docker.com/linux/debian

# distribution=any against a remote already ending in /any/, so the upstream path
# really is .../helm-debian/any/dists/any/. Preserved verbatim.
Remap-helmapt: /repository/helm-apt ; https://packages.buildkite.com/helm-linux/helm-debian/any
EOF

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
  echo "</ul><h2>APT (${#APT_REPOS[@]})</h2><ul>"
  for r in "${APT_REPOS[@]}"; do echo "<li><code>/repository/${r}/</code></li>"; done
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

# Build the apt route matcher from the table above, so the Caddyfile and the
# Remap table cannot drift apart silently.
apt_alternation="$(IFS='|'; echo "${APT_REPOS[*]}")"

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
  echo "  # ---- APT: ${#APT_REPOS[@]} repositories, one upstream ----"
  echo "  @apt path_regexp ^/repository/(${apt_alternation})(/|\$)"
  echo "  handle @apt {"
  echo "    reverse_proxy apt-cache:3142 {"
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

  echo "  # ---- Helm chart repositories ----"
  for entry in "${HELM_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "  handle_path /repository/${name}/* {"
    [[ -n "${path}" ]] && echo "    rewrite * ${path}{uri}"
    echo "    reverse_proxy https://${host} {"
    echo "      header_up Host ${host}"
    strip_forwarded
    echo "    }"
    echo "  }"
  done
  echo

  echo "  # ---- Raw HTTP proxies ----"
  for entry in "${RAW_REPOS[@]}"; do
    IFS=: read -r name host path <<<"${entry}"
    echo "  handle_path /repository/${name}/* {"
    [[ -n "${path}" ]] && echo "    rewrite * ${path}{uri}"
    echo "    reverse_proxy https://${host} {"
    echo "      header_up Host ${host}"
    strip_forwarded
    echo "    }"
    echo "  }"
  done
  echo

  echo "  handle {"
  echo "    root * /site"
  echo "    file_server"
  echo "  }"
  echo
  echo "  log {"
  echo "    output file /data/logs/mirror-access.log"
  echo "    format console"
  echo "  }"
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

  # Docker Hub serves official images under library/. A client pulling
  # dockerhub.<domain>/busybox sends "busybox", which Hub answers with 401;
  # Nexus added the prefix itself. Multi-segment names, /v2/ and /v2/_catalog
  # do not match, and containerd mirrors already send library/.
  hub_short_names() {
    echo "  @hubshort path_regexp hub ^/v2/([^/]+)/(manifests|blobs|tags|referrers)/(.*)\$"
    echo "  rewrite @hubshort /v2/library/{re.hub.1}/{re.hub.2}/{re.hub.3}"
  }

  # ---- one pair of sites per registry, same split ----
  for entry in "${REGISTRIES[@]}"; do
    IFS=: read -r name sub _ _ <<<"${entry}"
    echo "$(regional_host "${sub}") {"
    [[ "${name}" == "dockerhub" ]] && hub_short_names
    echo "  import registry_proxy registry-${name}:5000"
    echo "  log {"
    echo "    output file /data/logs/${name}-access.log"
    echo "    format console"
    echo "  }"
    echo "}"
    echo
    if [[ -n "${GLOBAL_BASE_DOMAIN}" ]]; then
      echo "$(global_host "${sub}") {"
      echo "  import globalcert"
      [[ "${name}" == "dockerhub" ]] && hub_short_names
      echo "  import registry_proxy registry-${name}:5000"
      echo "  log {"
      echo "    output file /data/logs/${name}-access.log"
      echo "    format console"
      echo "  }"
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
  echo "    image: ${CADDY_IMAGE}"
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
  echo
  echo "  apt-cache:"
  echo "    build:"
  echo "      context: ."
  echo "      dockerfile: Dockerfile.acng"
  echo "    container_name: apt-cache"
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
log "Building images (Nexus still serving)"
cd "${STACK_DIR}"
docker compose build

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
  log "acng.conf changed, restarting apt-cache"
  docker compose restart apt-cache
else
  log "acng.conf unchanged"
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
check "apt  kubernetes-v1-34" '^200$' "https://${BASE_DOMAIN}/repository/kubernetes-v1-34/Release"
check "helm helm-tigera" '^200$' "https://${BASE_DOMAIN}/repository/helm-tigera/index.yaml"
check "helm helm-metrics-server" '^200$' "https://${BASE_DOMAIN}/repository/helm-metrics-server/index.yaml"
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

  12 Remap entries, 7 registry containers (${REGISTRY_IMAGE%@*}),
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
