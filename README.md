# sonartype-installer

One shell script that turns a bare Linux host into a caching pull-through mirror
for the public container registries, APT suites and Helm charts a Kubernetes
cluster pulls from — nginx, `ghcr.io/glueops/registry` and Caddy, with TLS, on a
domain you own.

It is idempotent: re-running it against a live host reconciles configuration
rather than rebuilding, so it doubles as the upgrade path.

```bash
sudo BASE_DOMAIN=repo.example.com \
     ACME_EMAIL=admin@example.com \
     bash install-mirror-stack.sh
```

## How it works

| What | Served by |
| --- | --- |
| 27 apt repositories | nginx (`apt-nginx`), 7 upstream hosts (below) |
| 7 container registries | 7 × [`ghcr.io/glueops/registry`](https://github.com/GlueOps/registry) pull-through (below) |
| 4 helm + 6 raw repositories | nginx cache behind Caddy |
| `https://<BASE_DOMAIN>/` | a static index of what the host serves, plus `/healthz` |

Every path-addressed repository lives at `/repository/<name>/`. Those URLs are
what clients already use, so a name is not free to change.

Every cache is plain local disk. Upstream is explicit that a pull-through
registry cache uses the `filesystem` storage driver; apt, helm and raw cache in
`nginx:alpine` behind Caddy, which stays the stock `caddy:2` image.

### Retention

| layer | setting | effect |
| --- | --- | --- |
| apt-nginx (packages) | `inactive=45d` + `APT_CACHE_MAX_SIZE` (40g) | LRU; a file unused for 45 days is dropped |
| apt-nginx (indexes) | `1s`, revalidated, stale on error | fresh on every `apt-get update`, last good copy in an outage |
| nginx (raw) | always revalidate, stale on error | those are stable paths whose *content moves* |
| nginx (helm index) | `5m` | an index is the thing that moves |
| nginx (eviction) | `inactive=365d` + `max_size` | LRU, disk pressure only |
| registries | `REGISTRY_PROXY_TTL=0` | never deleted |

Retention is not freshness. Raising the *freshness* window on raw would be a
regression: `dl.k8s.io/release/stable.txt` and friends are stable paths whose
content moves, which is why they revalidate on every request.

### Nothing is stopped until everything is in hand

Images are **pulled before the current stack is touched**. `docker
compose up` otherwise fetches what it lacks *after* the teardown, so an
unreachable registry, an expired credential or a withdrawn tag becomes an outage
rather than a refusal.

One deploy has already hit this: a stale `ghcr.io` credential on a host turned a
public image into `error from registry: denied`, and the mirror only stayed up
because compose happened to fail before replacing the running containers.

A public image failing to pull usually means the host is sending a stale
credential rather than pulling anonymously — docker sends any credential it
holds, and an expired one is refused instead of falling back:

```sh
cat /root/.docker/config.json     # an auths entry for the registry
docker logout <registry>
```

`DRY_RUN=1` writes the compose file, Caddyfile, `nginx.conf` and
`apt-nginx.conf` and stops.

### Upgrading a host that ran apt-cacher-ng

One run switches it over; nothing else is needed.

- The `apt-cache` container is removed (it is no longer in the compose file, and
  the run uses `--remove-orphans`). Its cache in `apt-cache/` and `apt-log/`,
  `acng.conf`, `Dockerfile.acng` and its locally built image are **left in
  place**; delete them when convenient. Nothing uses them.
- apt is unavailable for a few seconds during the switch.
- Caddy and content-cache are recreated once (a new sysctl and a pinned nginx
  image), so every route blips for a moment on that first run.
- The apt cache starts cold. Indexes and packages are fetched on first use; a
  package that was never fetched is not available while its upstream is down.

### Two things that will bite you

**Regional and global names cannot share a Caddy site block.** A wildcard for
`repo.example.com` covers `repo.example.com` and `*.repo.example.com` — so
`dockerhub.repo.example.com` is in scope. It does **not** cover
`repo.eu-central.example.com`; that is a different name, not a subdomain. A
`tls` directive applies to every address on its block, so merging them hands the
regional names a certificate that does not match. The generated Caddyfile keeps
them apart: regional on ACME, global on the pre-issued wildcard.

**`X-Forwarded-*` is stripped from apt, helm and raw upstream requests.** Those
are third-party CDNs being fetched as an ordinary client. `packages.buildkite.com` is the proof: it answers a request carrying
`X-Forwarded-Host` with a 301 to its marketing site instead of the signed URL
for the signing key. The registry routes keep their headers; those backends are
yours.

### Registries run `ghcr.io/glueops/registry`

[`ghcr.io/glueops/registry`](https://github.com/GlueOps/registry) is Distribution
3.1.1 plus one fix for ECR Public
([distribution#4383](https://github.com/distribution/distribution/issues/4383)), so
`ecr.` is cached like the other registries. It's pinned in `REGISTRY_IMAGE`.

- **Egress**: ECR redirects blobs to CloudFront; the registry follows that itself,
  so only the mirror host needs to reach CloudFront.
- **Rate limits**: anonymous ECR Public throttles per source IP, and each uncached
  blob costs about 3 requests to ECR. A burst of cold pulls can hit
  `toomanyrequests`; cached images are unaffected.
- **`REGISTRY_PROXY_TTL=0`**: nothing is evicted, so `registries/` only grows.
  That's today's behaviour too (`registry:2` has deletes disabled, so its expiry
  never removed anything); the new image would actually delete, including during an
  outage. To reclaim space for one registry: stop `registry-<name>`, delete
  `registries/<name>`, start it again. It refills on demand.
- **`REGISTRY_PROXY_EXEC_COMMAND`**: an anonymous credential helper. Without one the
  registry panics at startup when its upstream is unreachable, so a restart during
  an outage would crash-loop.
- Logging is `info` and container logs are capped (`LOG_MAX_SIZE` × `LOG_MAX_FILES`,
  default 50m × 5 per container).

Existing `registry:2` caches are reused as-is: the on-disk layout is the same, and
they're served offline after the switch (tested).

### Docker Hub official images

Docker Hub keeps official images under `library/`, and the docker daemon adds
that prefix only when talking to Hub **directly**. Through a mirror hostname it
sends whatever you typed:

```console
$ docker pull <mirror>/nginx:trixie-perl
Error response from daemon: manifest unknown

$ docker pull <mirror>/library/nginx:trixie-perl   # works
```

Caddy rewrites the single-segment form for the hosts in `OFFICIAL_NAMESPACE`.
The pattern requires the segment after the repository name to be
`manifests`/`blobs`/`tags`, which confines it: `/v2/grafana/grafana/manifests/…`
has `grafana` followed by `grafana`, so a namespaced image is left alone, and
`/v2/` and `/v2/_catalog` do not match.

### Access logs

`format json` with bounded rolling, not the console format. These are files
nobody tails, and json is what makes "which repositories is this mirror actually
serving, and how much" answerable.

The roll limits matter: Caddy defaults to 100MiB × 10 per log and this stack
writes several of them, so the default ceiling is gigabytes of logs on a host
whose whole job is caching.

### APT goes through nginx

`apt-nginx` replaces apt-cacher-ng, which truncated a response whenever several
nodes refreshed the same expired index at once, failed every index with 503
while an upstream was down, and percent-encoded the colons in `pkgs.k8s.io`
paths into a spelling CloudFront served month-old indexes for.

**Two tiers in one container.** `:3142` caches: keys, 1 MB slices, locks and
stale copies. A loopback server on `127.0.0.1:8091` fetches: DNS, TLS
verification, keepalive and redirect following, and it never caches. They must
stay apart: a slice subrequest that follows a redirect loses its `Range` and
splices a whole body into the file.

**Indexes are cached for 1s and revalidated by date.** `InRelease`, `Packages`
and the rest are rewritten in place on every publish, and apt fails with `File
has unexpected size` when it gets an `InRelease` and a `Packages` from different
publishes. A short lifetime, no background refresh and no `updating` in
`proxy_cache_use_stale` keep them from the same publish; the last good copy is
still served when the upstream errors or times out. Revalidation sends only
`If-Modified-Since`, so a lagging mirror answers 304 instead of replacing a newer
copy with an older one.

**Packages, `by-hash` and pdiffs never change**, so they are never revalidated:
kept until evicted (unused for 45 days, or the size cap) and fetched in 1 MB
slices: thirteen nodes asking for the same cold package cause one
upstream fetch per slice, and each receives bytes as its slice lands. The cache
key is the upstream host and path, so the six `ubuntu-*` release and `-updates`
repositories share one copy of the pool; the three `-security` ones share another.

**What it refuses.** Only the repositories in `APT_REPOS`, only index and package
paths, only `GET`/`HEAD` without a body, no query strings and no escapes other
than the `%7e`/`%2b` apt itself sends. The fetch tier talks only to the seven hosts
in the table and verifies their certificates, and follows a redirect only to
`*.cloudfront.net`, checked on every hop.

**Sizes.** `APT_CACHE_MAX_SIZE` (default 40g) caps the package cache and
`APT_CACHE_MIN_FREE` (default 10g) is free disk nginx evicts to keep, since the
registries share the disk. Indexes have their own 10g zone, so package churn
cannot evict what an outage depends on. Changing either size recreates the
apt-nginx container (nginx cannot reload a cache zone), so apt is unavailable
for a few seconds on that run.

Runbooks:

- **One cached file is bad.** Delete every slice of it; the next request refetches:
  ```sh
  grep -rlaF "KEY: archive.ubuntu.com/ubuntu/pool/main/h/hello/hello_2.10-3build1_amd64.deb" \
    /opt/mirror-stack/apt-nginx-cache | xargs -r rm -f
  ```
- **A Debian `-updates`/`-security` suite is expired.** Those suites carry
  `Valid-Until` seven days out, so after about a week of upstream outage apt
  refuses the cached copy. That needs a change on the nodes, not the mirror:
  `Acquire::Check-Valid-Until "false";` in `/etc/apt/apt.conf.d/`, removed afterwards.
- **A new Kubernetes minor.** Add its row to `APT_REPOS` and re-run.

### Helm and raw go through nginx

Caddy fronts everything and terminates TLS. Behind it, nginx does the three
things Caddy cannot: keep a copy, serve that copy when the upstream is
unreachable, and rewrite a response body.

**Chart URLs are rewritten.** A Helm `index.yaml` carries absolute download
URLs — 219 pointing at `github.com` across tigera, metrics-server and
containeroo, and 11,652 at `charts.helm.sh` in the archived helm-stable. Caddy
cannot rewrite them, so `helm install` would fetch the index from the mirror and
the chart from GitHub. nginx rewrites them with `sub_filter`.

Note `proxy_set_header Accept-Encoding "";` on those locations. Every one of
those indexes serves gzip when asked, and **`sub_filter` cannot touch a
compressed body** — without it the rewrite silently does nothing at all.

**Redirects are followed server-side.** `github.com`, `pkgs.k8s.io` and
`packages.buildkite.com` all answer a download with a 302 to a CDN. Handing that
back means the client needs its own egress, nothing is cached, and an outage is
a hard failure. nginx follows them with `proxy_intercept_errors` and a named
location, for chains of up to 10 hops. The cache key stays the **original
request path**: buildkite's
CloudFront URLs are signed and expiring, and GitHub's asset CDN hostname has
already changed once, so keying on the target would never hit.

**Stale is served on error.** `proxy_cache_use_stale error timeout updating
http_5xx` is the point of the whole component. Verified: with an entry's TTL
expired and the upstream resolving to an unroutable address, a cached path
returns 200 from disk while a path that was never cached returns 504.

**Raw revalidates on every request**: `proxy_cache_valid 1s`, upstream cache headers ignored, and the cached copy
served on error, timeout, 5xx, 429, 403 and 404. A refused connection falls
back immediately, an unreachable upstream after 5s per address with no new
attempt after 10s, and a hanging one after 30s (read timeout). The 10s only
stops new attempts, so one started just before it can still run its full
timeouts: the worst case is about 40s. Two cases get no cached copy: a redirect chain longer than 10
hops (500), and a redirect target whose DNS fails (502).

**Upstreams resolve IPv4 only.** Each helm and raw host is an `upstream` block
with `server <host>:443 resolve`, looked up through Docker's DNS with
`ipv6=off` and re-resolved every 30s. A plain `proxy_pass` hostname is resolved
once at startup by musl, which keeps AAAA records whenever `::1` exists, and the
compose network has no IPv6 route: nginx then tried unreachable IPv6 addresses
first. The stack assumes an IPv4-only compose network.

**Helm indexes get the same fallback and header handling** (`cache_resilience`),
but keep a 5-minute lifetime (previously 10 where upstream sent `max-age=600`) and
refresh in the background, so an expired index is served at once and no client
waits on the upstream.

Two settings that are not optional. `proxy_buffer_size 32k` — GitHub's 302
carries a signed URL long enough that the default 4k buffer fails the request as
`upstream sent too big header`. And `proxy_max_temp_file_size` must **not** be
0: nginx writes a response to a temp file on its way into the cache, so
disabling that silently stops anything larger than the buffers from ever being
cached.

## Using the mirror

Every registry gets its own hostname, because the Docker registry protocol has
no way to select a backend from the path — the hostname is the only routing
signal a `docker pull` sends. Swap the upstream host for the mirror host and
keep the rest of the reference:

```
docker pull gcr.io/kaniko-project/executor:latest
docker pull gcr.<BASE_DOMAIN>/kaniko-project/executor:latest
```

| Upstream registry | Mirror hostname |
| --- | --- |
| `docker.io` | `dockerhub.<BASE_DOMAIN>` |
| `ghcr.io` | `ghcr.<BASE_DOMAIN>` |
| `quay.io` | `quay.<BASE_DOMAIN>` |
| `public.ecr.aws` | `ecr.<BASE_DOMAIN>` |
| `registry.k8s.io` | `k8s.<BASE_DOMAIN>` |
| `us-docker.pkg.dev` | `gcp.<BASE_DOMAIN>` |
| `gcr.io` | `gcr.<BASE_DOMAIN>` |

Everything else is path-addressable, shares the one hostname `<BASE_DOMAIN>`,
and is reached at `https://<BASE_DOMAIN>/repository/<name>/`:

| Kind | Repos | Upstream |
| --- | --- | --- |
| APT | `ubuntu-jammy`, `ubuntu-noble`, `ubuntu-resolute` (+ `-updates`, `-security`) | `archive.ubuntu.com`, `security.ubuntu.com` |
| APT | `debian-bookworm`, `debian-trixie` (+ `-updates`, `-security`) | `deb.debian.org`, `security.debian.org` |
| APT | `kubernetes-v1-32` … `kubernetes-v1-37` | `pkgs.k8s.io/core:/stable:/vX.Y/deb/` |
| APT | `helm-apt` | `packages.buildkite.com/helm-linux/helm-debian` |
| APT | `docker-ubuntu-jammy`, `docker-ubuntu-noble`, `docker-ubuntu-resolute` | `download.docker.com/linux/ubuntu` |
| APT | `docker-debian-bookworm`, `docker-debian-trixie` | `download.docker.com/linux/debian` |
| Helm | `helm-tigera` | `docs.tigera.io/calico/charts` |
| Helm | `helm-metrics-server` | `kubernetes-sigs.github.io/metrics-server` |
| Helm | `helm-containeroo` | `charts.containeroo.ch` |
| Helm | `helm-stable` | `charts.helm.sh/stable` (archived upstream) |
| Raw | `raw-k8s` | `dl.k8s.io` |
| Raw | `raw-helm` | `get.helm.sh` |
| Raw | `raw-pkgs-k8s` | `pkgs.k8s.io` |
| Raw | `raw-docker` | `download.docker.com` |
| Raw | `raw-buildkite-helm` | `packages.buildkite.com/helm-linux/helm-debian` |
| Raw | `raw-github` | `github.com` |

Each APT suite is its own repository. `resolute` is Ubuntu 26.04 LTS; the
codename, not the number, is what an APT suite is addressed by.

Signing keys come through the raw repositories, which is also why `raw-docker`
proxies the host root: one repository covers both of Docker's trees.

```
https://<BASE_DOMAIN>/repository/raw-pkgs-k8s/core:/stable:/v1.34/deb/Release.key
https://<BASE_DOMAIN>/repository/raw-docker/linux/ubuntu/gpg
https://<BASE_DOMAIN>/repository/raw-buildkite-helm/gpgkey
```

### The two Google registries are not interchangeable

`gcr.io` and `us-docker.pkg.dev` are separate namespaces — neither serves the
other's paths and there is no redirect between them. Artifact Registry paths are
`<project>/<repo>/<image>` (three segments); `gcr.io` paths are
`<project>/<image>` (two). Pick the mirror matching the host you started with.

Misses from either Google registry return `401`, not `404` — Artifact Registry
does not disclose whether a private or nonexistent repo exists. A typo'd path
surfaces as an auth error.

## Prerequisites

- Linux with Docker and the Compose plugin, and root.
- DNS records pointing every registry hostname above — plus `BASE_DOMAIN`
  itself — at the host, **before** you run it. Caddy fails its ACME challenge
  for any name that does not yet resolve, and one failing site block is enough
  to keep Caddy from starting.
- Ports 80 and 443 reachable from the internet, for HTTP-01.

## Configuration

Everything is environment variables. `BASE_DOMAIN` and `ACME_EMAIL` are
required; the full list, with defaults, is in the header of
`install-mirror-stack.sh`.

### A second, global hostname

For a fleet of regional mirrors behind one latency-routed DNS record, set
`GLOBAL_BASE_DOMAIN` (e.g. `repo.example.com`) alongside the regional
`BASE_DOMAIN` (e.g. `repo.us-east.example.com`). Each host then serves both
names.

Caddy will not obtain the global cert: a name that resolves to a different
server on each lookup cannot complete HTTP-01. Issue one wildcard covering
`<GLOBAL_BASE_DOMAIN>` and `*.<GLOBAL_BASE_DOMAIN>` somewhere central — DNS-01,
once — and copy the pair to every host before running the script, which refuses
to start without it:

```
${STACK_DIR}/certs/<GLOBAL_CERT_NAME>.crt
${STACK_DIR}/certs/<GLOBAL_CERT_NAME>.key
```

`GLOBAL_CERT_NAME` defaults to `GLOBAL_BASE_DOMAIN`.

## License

Apache-2.0. See [LICENSE](LICENSE).
