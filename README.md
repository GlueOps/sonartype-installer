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
| 4 helm + 6 raw proxy repositories | Caddy `reverse_proxy`, straight to the upstream |
| Nexus UI | a static index of what the host serves, plus `/healthz` |

No admin user, no EULA, and no *Docker Bearer Token Realm* to switch on by hand
after every rebuild. Client URLs are unchanged: `/repository/<name>/` is a Nexus
path convention, but apt-cacher-ng's `Remap` and Caddy's `handle_path` reproduce
it verbatim, so no `sources.list` or `helm repo add` in your estate has to move.

Every cache is plain local disk. Upstream is explicit that a pull-through
registry cache uses the `filesystem` storage driver, and all six raw proxies ran
`contentMaxAge=0` under Nexus — always revalidate — so a plain `reverse_proxy`
is a faithful replacement and no HTTP cache module is needed. This runs the
stock `caddy:2` image.

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

### Redirects are passed through, not followed

Nexus followed upstream redirects server-side, so a client only ever talked to
the mirror. Caddy hands the 302 back instead. Three paths do this: `raw-github`
release assets, `raw-pkgs-k8s/…/Release.key`, and `raw-buildkite-helm/gpgkey`.

Rewriting `Location` back through the mirror was tried and removed. GitHub has
already moved release assets from `objects.githubusercontent.com` to
`release-assets.githubusercontent.com`, so a hardcoded CDN list is stale on
arrival and silently becomes a no-op; buildkite hands out a CloudFront URL whose
signature covers the exact URL and expires. A rewrite table that is wrong fails
closed on a path that would otherwise have worked.

The consequence is an egress one: those three fetches need the client to reach
the CDN. Nothing else is lost — no raw repository was caching anything anyway.

## Adding a repository

Every kind of upstream lives in one table near the top of
`install-mirror-stack.sh`. Add a line, re-run the installer, done — it is
idempotent and reloads only what changed.

**The name you choose becomes a URL.** Clients fetch
`https://<host>/repository/<name>/…`, so a rename is a breaking change for every
`sources.list` and `helm repo add` pointing at it. Pick it once.

### A Helm chart repository

`HELM_REPOS`, as `name:upstream host:upstream path prefix`:

```bash
"helm-cilium:helm.cilium.io:"
```

Served at `/repository/helm-cilium/`, proxied to `https://helm.cilium.io/`.
Leave the third field empty when the charts sit at the host root.

### A raw HTTP proxy

`RAW_REPOS`, same shape:

```bash
"raw-cni-plugins:github.com:/containernetworking/plugins/releases/download"
```

Raw proxies always revalidate against the upstream — there is no local copy to
go stale — so this is the right table for anything whose content moves under a
stable path.

If the upstream answers with a redirect to a CDN, the client follows it itself;
see *Redirects are passed through, not followed* above. That is a deliberate
choice, not an oversight.

### A container registry

One line, and some DNS.

`REGISTRIES`, as `name:subdomain:host port:upstream`:

```bash
"mcr:mcr:5007:https://mcr.microsoft.com"
```

Then, **before deploying**:

1. Create the DNS record for `<subdomain>.<BASE_DOMAIN>` — and for
   `<subdomain>.<GLOBAL_BASE_DOMAIN>` if you run a global hostname.
2. Pick an unused host port. The existing ones run 5000–5006.

Each registry gets its own hostname because the Docker registry protocol has no
way to select a backend from the path — the hostname is the only routing signal
a `docker pull` sends.

**Mind the certificate budget.** A new subdomain means a new regional ACME
certificate per host. Let's Encrypt allows 50 per registered domain per week,
and a three-host fleet already issues 8 per host. Adding registries in bulk, or
rebuilding the fleet from empty afterwards, can exhaust that.

Registries pull anonymously, through one shared helper that the script rewrites on
every run. To authenticate to an upstream you have to edit the script: mount a
per-registry helper that prints `{"Username":"…","Secret":"…"}`, and for expiring
tokens (e.g. ECR, 12h) set `REGISTRY_PROXY_EXEC_LIFETIME`, or the first token is
cached until the container restarts. Anyone who can reach the mirror can then pull
whatever that account can.

### An APT suite

Two places, and the second one decides how much disk you use.

First, `APT_REPOS` — this is only the routing list, so Caddy knows to send that
prefix to apt-cacher-ng:

```bash
ubuntu-questing ubuntu-questing-updates ubuntu-questing-security
```

Second, a `Remap` line in the `acng.conf` heredoc. **Several local prefixes on
one `Remap` share a single cache tree**, and that is the whole decision:

```
Remap-<name>: /repository/<a> /repository/<b> ; https://upstream/path
```

- **Merge** suites that differ only by the suite name in the path and share an
  identical `pool/`. The nine `ubuntu-*` repositories are one `Remap` for
  exactly this reason — separate trees would store every `.deb` nine times.
- **Do not merge** archives that are genuinely separate.
  `security.debian.org` has its own `pool/`, so it gets its own `Remap` even
  though it is also Debian.
- **Flat repositories** — `pkgs.k8s.io` publishes each Kubernetes minor as an
  independent tree with nothing to share — get one `Remap` each.

An upstream reachable only over HTTPS is fine as a target; remapping a plain
client-facing path onto an HTTPS upstream is the documented way to cache one.

After adding, confirm the suite actually resolves:

```bash
curl -sI https://<host>/repository/<name>/dists/<suite>/InRelease
```

A 404 there usually means the upstream does not carry that suite yet — Docker
publishes no suite for an Ubuntu release on the day it ships — rather than that
the `Remap` is wrong.


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
