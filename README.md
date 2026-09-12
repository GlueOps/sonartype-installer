# sonartype-installer

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

## What it builds

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

Plus APT proxies (Ubuntu jammy/noble, Debian bookworm/trixie, each with
`-updates` and `-security`, Kubernetes `v1.32`–`v1.35`, Helm), a Helm chart
proxy, and raw proxies for `dl.k8s.io` and `get.helm.sh`.

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

A registry touches seven places in `install.sh`. `grep -n P_GCR install.sh` to
see all of them at once: the port default, the regional and global derived
hostnames, the compose `ports`/`expose` lists, the two Caddy site blocks, the
`create_if_missing` proxy repository, the prewarm `case` arm, and the two
summary tables.

DNS comes first — Caddy fails the ACME challenge for a name that does not
resolve, and one failing site block is enough to keep Caddy from starting.

## License

Apache-2.0. See [LICENSE](LICENSE).
