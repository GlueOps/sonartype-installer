# sonartype-installer

> **Nexus Repository Community Edition enforces usage limits from 15 October
> 2026** — 40,000 components *or* 100,000 requests per day, and exceeding either
> one blocks *adding new components* until you are back under **both**. For a
> deployment that is entirely proxy repositories, **a cache miss is a component
> addition**, so going over the request cap does not throttle the mirror: it
> stops it caching anything it has not already cached.
>
> **[`install-mirror-stack.sh`](#install-mirror-stacksh) builds the same mirror
> without Nexus**, and migrates a host that already runs one. `install.sh` below
> is unchanged and still supported for deployments that stay under the limits.

One shell script that turns a bare Linux host into a caching pull-through mirror
for the public container registries, APT suites and Helm charts a Kubernetes
cluster pulls from — Sonatype Nexus behind Caddy, with TLS, on a domain you own.

It is idempotent: re-running it against a live host reconciles configuration
rather than rebuilding, so it doubles as the upgrade path.

```bash
sudo BASE_DOMAIN=repo.example.com \
     ACME_EMAIL=admin@example.com \
     NEXUS_NEW_ADMIN_PASSWORD='<a password you generated>' \
     bash install.sh
```

## `install-mirror-stack.sh`

The same mirror, decomposed by protocol, with no licence meter.

```bash
sudo BASE_DOMAIN=repo.example.com \
     ACME_EMAIL=admin@example.com \
     bash install-mirror-stack.sh
```

| Was, under Nexus | Is |
| --- | --- |
| 27 apt proxy repositories | apt-cacher-ng, **12** `Remap` entries |
| 7 docker proxy repositories | 7 × [`ghcr.io/glueops/registry`](https://github.com/GlueOps/registry) pull-through (below) |
| 4 helm + 6 raw proxy repositories | nginx cache behind Caddy |
| Nexus UI | a static index of what the host serves, plus `/healthz` |

No admin user, no EULA, and no *Docker Bearer Token Realm* to switch on by hand
after every rebuild. Client URLs are unchanged: `/repository/<name>/` is a Nexus
path convention, but apt-cacher-ng's `Remap` and Caddy's `handle_path` reproduce
it verbatim, so no `sources.list` or `helm repo add` in your estate has to move.

Every cache is plain local disk. Upstream is explicit that a pull-through
registry cache uses the `filesystem` storage driver; helm and raw cache in
`nginx:alpine` behind Caddy, which stays the stock `caddy:2` image.

### Nothing is stopped until everything is in hand

Images are **built and pulled before the current stack is touched**. `docker
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

### Migrating from Nexus

If a stack built by `install.sh` is present, it is **stopped, not deleted**, and
its TLS material is carried across first. Rollback is a compose up in the old
stack directory. On a host with no Nexus, that phase is skipped entirely.

Images are built *before* anything is stopped, so a failed build is not an
outage. `DRY_RUN=1` writes the compose file, Caddyfile and `acng.conf` and stops.

### Two things that will bite you

**Regional and global names cannot share a Caddy site block.** A wildcard for
`repo.example.com` covers `repo.example.com` and `*.repo.example.com` — so
`dockerhub.repo.example.com` is in scope. It does **not** cover
`repo.eu-central.example.com`; that is a different name, not a subdomain. A
`tls` directive applies to every address on its block, so merging them hands the
regional names a certificate that does not match. The generated Caddyfile keeps
them apart: regional on ACME, global on the pre-issued wildcard.

**`X-Forwarded-*` is stripped from helm and raw upstream requests.** Those are
third-party CDNs being fetched as an ordinary client, which is what Nexus did.
`packages.buildkite.com` is the proof: it answers any request carrying an
`X-Forwarded-Proto` with a 301 to its marketing site instead of the signed URL
for the signing key — whether the value says `http` or `https`. The registry and
apt routes keep their headers; those backends are yours.

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

### Helm and raw go through nginx

Caddy fronts everything and terminates TLS. Behind it, nginx does the three
things Caddy cannot: keep a copy, serve that copy when the upstream is
unreachable, and rewrite a response body.

**Chart URLs are rewritten.** A Helm `index.yaml` carries absolute download
URLs — 219 pointing at `github.com` across tigera, metrics-server and
containeroo, and 11,652 at `charts.helm.sh` in the archived helm-stable. Nexus
rewrote them to itself; Caddy could not, so `helm install` fetched the index
from the mirror and the chart from GitHub. nginx rewrites them with
`sub_filter`.

Note `proxy_set_header Accept-Encoding "";` on those locations. Every one of
those indexes serves gzip when asked, and **`sub_filter` cannot touch a
compressed body** — without it the rewrite silently does nothing at all.

**Redirects are followed server-side.** `github.com`, `pkgs.k8s.io` and
`packages.buildkite.com` all answer a download with a 302 to a CDN. Handing that
back means the client needs its own egress, nothing is cached, and an outage is
a hard failure. nginx follows them with `proxy_intercept_errors` and a named
location, for chains of up to 10 hops. The cache key stays the **original request path**: buildkite's
CloudFront URLs are signed and expiring, and GitHub's asset CDN hostname has
already changed once, so keying on the target would never hit.

**Stale is served on error.** `proxy_cache_use_stale error timeout updating
http_5xx` is the point of the whole component. Verified: with an entry's TTL
expired and the upstream resolving to an unroutable address, a cached path
returns 200 from disk while a path that was never cached returns 504.

**Raw revalidates on every request**, as `contentMaxAge: 0` did under Nexus:
`proxy_cache_valid 1s`, upstream cache headers ignored, and the cached copy
served on error, timeout, 5xx, 429, 403 and 404. A stopped upstream costs 5s
(connect timeout) and a hanging one 30s (read timeout) before the cached copy is
served. Two cases get no cached copy: a redirect chain longer than 10 hops
(500), and a redirect target whose DNS fails (502).

Two settings that are not optional. `proxy_buffer_size 32k` — GitHub's 302
carries a signed URL long enough that the default 4k buffer fails the request as
`upstream sent too big header`. And `proxy_max_temp_file_size` must **not** be
0: nginx writes a response to a temp file on its way into the cache, so
disabling that silently stops anything larger than the buffers from ever being
cached.

## `install.sh` (Nexus)

### What it builds

| Component | Where |
| --- | --- |
| Nexus 3 | container `nexus`, data in `/opt/nexus/nexus-data`, bound to `127.0.0.1` only |
| Caddy | container `nexus-caddy`, the only thing on `:80`/`:443` |
| Compose + Caddyfile | generated into `/opt/nexus-stack` |

Every registry gets its own hostname and its own Nexus Docker port, because the
Docker registry protocol has no way to select a backend from the path — the
hostname is the only routing signal a `docker pull` sends.

| Upstream registry | Mirror hostname | Nexus repo | Port |
| --- | --- | --- | --- |
| `docker.io` | `dockerhub.<BASE_DOMAIN>` | `dockerhub` | 5000 |
| `ghcr.io` | `ghcr.<BASE_DOMAIN>` | `ghcr` | 5001 |
| `quay.io` | `quay.<BASE_DOMAIN>` | `quay` | 5002 |
| `public.ecr.aws` | `ecr.<BASE_DOMAIN>` | `public-ecr` | 5003 |
| `registry.k8s.io` | `k8s.<BASE_DOMAIN>` | `registry-k8s-io` | 5004 |
| `us-docker.pkg.dev` | `gcp.<BASE_DOMAIN>` | `us-docker-pkg-dev` | 5005 |
| `gcr.io` | `gcr.<BASE_DOMAIN>` | `gcr-io` | 5006 |

Everything else is path-addressable, so it shares the one hostname
`<BASE_DOMAIN>` and is reached at `https://<BASE_DOMAIN>/repository/<name>`.

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
| Helm | `helm-stable` | `charts.helm.sh/stable` (archived upstream, see below) |
| Raw | `raw-k8s` | `dl.k8s.io` |
| Raw | `raw-helm` | `get.helm.sh` |
| Raw | `raw-pkgs-k8s` | `pkgs.k8s.io` |
| Raw | `raw-docker` | `download.docker.com` |
| Raw | `raw-buildkite-helm` | `packages.buildkite.com/helm-linux/helm-debian` |
| Raw | `raw-github` | `github.com` |

A Nexus APT proxy pins one distribution, which is why each suite is its own
repository rather than a component of a shared one.

`resolute` is Ubuntu 26.04 LTS. The codename, not the number, is what an APT
suite is addressed by, and it is also what `ansible_distribution_release` and
friends hand you — so a mirror that tracks the number is a mirror that will be
edited again in two years.

`helm-stable` fronts the Helm chart repository archived in 2020. It is kept
because this script never deletes: dropping the line would leave the repository
in place on every host that already ran an older version, with nothing in the
script left to describe it.

### Why signing keys need their own raw proxies

A node cannot add a suite until it has the key that signs it, and an APT proxy
will not serve that key. Nexus recognises `Release`, `InRelease`, `Release.gpg`,
`Packages` and `pool/`, and refuses to fetch anything else from upstream — so
`pkgs.k8s.io`'s `Release.key`, which sits directly beside the suite, is a 404
through `kubernetes-v1-34` and has to come through `raw-pkgs-k8s` instead.

That is also why `raw-docker` proxies the host root rather than a key path: one
repository then covers both of Docker's trees.

```
https://<BASE_DOMAIN>/repository/raw-pkgs-k8s/core:/stable:/v1.34/deb/Release.key
https://<BASE_DOMAIN>/repository/raw-docker/linux/ubuntu/gpg
https://<BASE_DOMAIN>/repository/raw-buildkite-helm/gpgkey
```

`raw-github` is for release assets. A GitHub release download answers `302` to
`objects.githubusercontent.com`; Nexus follows it, so the host needs egress to
that CDN name as well as to `github.com`.

### Why the raw proxies revalidate and the others do not

Every `raw-*` repository sets `contentMaxAge: 0`; apt and Helm keep `-1`.

The split is about whether a path is version-addressed. A `.deb` or a `.tgz`
names its version, so the bytes at that path never legitimately change and
caching them forever is correct — a TTL there would buy nothing but revalidation
traffic. Raw has no such guarantee, and no metadata class either: Nexus cannot
tell a pinned tarball from a mutable pointer, so *everything* in a raw
repository is content and `-1` freezes all of it permanently.

Two of these proxies front pointers that genuinely move:

```
dl.k8s.io/release/stable.txt     -> v1.37.0
get.helm.sh/helm-latest-version  -> v4.3.0
```

And the signing keys are worse than stale, because the metadata they are checked
against *does* refresh — `metadataMaxAge` is 1440 either way. A permanently
cached key plus a fresh `Release` means the mirror serves a signature its own
clients cannot verify, and an apt source pinned with `signed-by=` fails hard
rather than falling back.

`contentMaxAge: 0` does not mean "always fetch". Nexus issues a conditional
request and serves the cache on a `304` — every upstream here supports that,
including `pkgs.k8s.io` via its CDN redirect. It also serves the cache when
revalidation fails outright, so an unreachable or erroring upstream degrades to
the cached copy rather than to an error.

`install-mirror-stack.sh` reproduces this in nginx; see *Stale is served on
error* above.

### Changing a repository that already exists

`create_if_missing` matches on name and nothing else. It will not reconcile a
repository it finds, which is deliberate — it is what lets you tune a proxy in
the UI without this script reverting you on the next run. The cost is that a
settings change here does not reach a mirror that already ran an older version.

To push one, `PUT` the full body; Nexus replaces rather than merges:

```bash
curl -u "admin:${NEXUS_NEW_ADMIN_PASSWORD}" -X PUT \
  -H 'Content-Type: application/json' \
  "https://${BASE_DOMAIN}/service/rest/v1/repositories/raw/proxy/raw-k8s" \
  -d @- <<'JSON'
{ ... the payload from install.sh, with contentMaxAge 0 ... }
JSON
```

Only repositories whose definition changed need this. On a mirror built before
the raw proxies revalidated, that is `raw-k8s` and `raw-helm`; the other four
are new and get the right value from the create.

To use a mirror, swap the upstream host for the mirror host and keep the rest of
the reference:

```
docker pull gcr.io/kaniko-project/executor:latest
docker pull gcr.<BASE_DOMAIN>/kaniko-project/executor:latest
```

### The two Google registries are not interchangeable

`gcr.io` and `us-docker.pkg.dev` are separate namespaces — neither serves the
other's paths and there is no redirect between them. Artifact Registry paths are
`<project>/<repo>/<image>` (three segments); `gcr.io` paths are
`<project>/<image>` (two). Pick the mirror matching the host you started with.

Mirroring `europe-docker.pkg.dev` or `asia-docker.pkg.dev` buys nothing: an
Artifact Registry hostname identifies where a repository *lives*, not a replica
to pull it from, so the same image is not served from all three.

Misses from either Google registry return `401`, not `404` — Artifact Registry
does not disclose whether a private or nonexistent repo exists. A typo'd path
surfaces as an auth error.

## Prerequisites

- Linux with Docker and the Compose plugin. The script reads `/proc/meminfo` to
  size the JVM heap at 80% of system RAM, so it is Linux-only.
- `curl`, `python3`, and root.
- DNS `A`/`AAAA` records pointing every hostname in the table above — plus
  `BASE_DOMAIN` itself — at the host, **before** you run it. Caddy fails its
  ACME challenge for any name that does not yet resolve.
- Ports 80 and 443 reachable from the internet (for HTTP-01), or Route53
  credentials and `ENABLE_DNS_CHALLENGE=true` (for DNS-01).

## Configuration

Everything is environment variables. Required:

| Variable | Meaning |
| --- | --- |
| `BASE_DOMAIN` | Hostname of this mirror, e.g. `repo.example.com`. All registry hostnames are derived from it. |
| `ACME_EMAIL` | Contact address for the ACME account. |
| `NEXUS_NEW_ADMIN_PASSWORD` | Password the `admin` user is set to. On a re-run this is also how the script authenticates. |

Optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXUS_IMAGE` | `sonatype/nexus3:3.94.1` | Nexus image and tag. |
| `STACK_DIR` | `/opt/nexus-stack` | Where the compose file, Caddyfile and certs live. |
| `NEXUS_DATA_DIR` | `/opt/nexus/nexus-data` | Nexus data volume on the host. |
| `ENABLE_ANON` | `true` | Enable anonymous access, so clients pull without credentials. |
| `ENABLE_DNS_CHALLENGE` | `false` | Use Route53 DNS-01 instead of HTTP-01. Builds a Caddy image with the `route53` DNS module. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` | — | Route53 credentials, required when `ENABLE_DNS_CHALLENGE=true`. Also accepted without the `AWS_` prefix. |
| `AWS_REGION` | `us-east-1` | Route53 is global, but the SDK wants a region. |
| `P_DOCKERHUB` … `P_GCR` | `5000`–`5006` | Per-registry Nexus ports. |
| `PREWARM` / `PREWARM_IMAGES_FILE` | `false` | Pull manifests for a newline-separated list of images so the first real pull is warm. |

### S3 blob store

Set all four and the script creates a blob store named `s3` and points every
repository at it instead of `default`:

| Variable | Default |
| --- | --- |
| `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` | — (all four required) |
| `S3_PREFIX` | `nexus/` |
| `S3_REGION` | `us-east-1` |
| `S3_FORCE_PATH_STYLE` | `true` |

The script writes `nexus.blobstore.s3.ownership.check.disabled=true` to
`nexus.properties` so non-AWS S3-compatible endpoints work.

### A second, global hostname

For a fleet of regional mirrors behind one latency-routed DNS record, set
`GLOBAL_BASE_DOMAIN` (e.g. `repo.example.com`) alongside the regional
`BASE_DOMAIN` (e.g. `repo.us-east.example.com`). Each host then serves both
names.

Caddy will not obtain the global cert: a name that resolves to a different
server on each lookup cannot complete HTTP-01. Issue one wildcard covering
`<GLOBAL_BASE_DOMAIN>` and `*.<GLOBAL_BASE_DOMAIN>` somewhere central — DNS-01,
once — and copy the pair to every host:

```
${STACK_DIR}/certs/<GLOBAL_CERT_NAME>.crt
${STACK_DIR}/certs/<GLOBAL_CERT_NAME>.key
```

`GLOBAL_CERT_NAME` defaults to `GLOBAL_BASE_DOMAIN`. The global site blocks fail
to serve until those files exist; the regional ones are unaffected, so a host
missing its cert still works on its regional name.

## After the first install

Two steps the REST API cannot do:

1. **Settings → Security → Realms**: move *Docker Bearer Token Realm* to Active.
   Docker clients and anonymous pulls do not work until you do.
2. Log in as `admin` and accept the EULA.

## Re-running and upgrading

Re-run with the same variables. The script authenticates with
`NEXUS_NEW_ADMIN_PASSWORD`, falls back to the generated `admin.password` on a
fresh install, skips repositories that already exist, and rewrites the compose
file and Caddyfile. Bumping `NEXUS_IMAGE` and re-running is the upgrade path.

It does not delete or reconcile repositories you have changed by hand — an
existing repository is left exactly as it is.

## Adding a mirror

A **Docker** registry touches seven places in `install.sh`. `grep -n P_GCR
install.sh` to see all of them at once: the port default, the regional and
global derived hostnames, the compose `ports`/`expose` lists, the two Caddy site
blocks, the `create_if_missing` proxy repository, the prewarm `case` arm, and
the two summary tables.

An APT, Helm or raw proxy touches one: a single `create_if_missing` line. It
needs no port, no hostname and no Caddy block, because only the Docker registry
protocol routes on the hostname — everything else is addressed by path under
`<BASE_DOMAIN>`, which already has a certificate.

DNS comes first — Caddy fails the ACME challenge for a name that does not
resolve, and one failing site block is enough to keep Caddy from starting.

## License

Apache-2.0. See [LICENSE](LICENSE).
