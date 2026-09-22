# AGENTS.md

Guidance for coding agents working in this repository. Everything here is
something that has actually gone wrong, not general advice.

## What this repository is

Two standalone installers. Neither imports the other; both generate a
`docker-compose.yml` and a `Caddyfile` into a stack directory and bring it up.

| Script | Builds | Status |
| --- | --- | --- |
| `install-mirror-stack.sh` | apt-cacher-ng + `ghcr.io/glueops/registry` + Caddy | current |
| `install.sh` | Sonatype Nexus + Caddy | legacy — under a usage meter from 15 Oct 2026 |

There is no build system, no test suite and no dependency manifest. A change is
a change to one shell script.

## CI will reject you for two things

**`shellcheck --severity=warning`** runs against both scripts. Run it before
pushing:

```bash
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable \
  --severity=warning install.sh install-mirror-stack.sh
```

**Conventional Commits are validated on every commit message in the PR**, not on
the PR title. A correctly titled PR with a plainly worded commit still fails.
Use `feat:`, `fix:`, `docs:`, `ci:`, `chore:`. If you have already committed
without a prefix, `git reset --soft` to the base and recommit rather than adding
a fixup.

## How to verify a change without a server

`DRY_RUN=1` writes every generated file and stops before touching Docker:

```bash
DRY_RUN=1 STACK_DIR=/tmp/x ACME_EMAIL=a@example.com \
  bash install-mirror-stack.sh repo.example.com
docker run --rm -v /tmp/x/Caddyfile:/etc/caddy/Caddyfile:ro \
  caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

Exercise both shapes. With `GLOBAL_BASE_DOMAIN` set you should get 16 site
blocks; without it, 8 and no `globalcert` snippet.

The whole stack also runs locally: rewrite the site addresses to `http://…`,
drop the `tls` directive, map port 80 to something unprivileged, and probe with
`-H "Host: …"`. Every route in this repository was verified that way against the
real upstreams before shipping.

## Landmines

**Caddy rejects one-liner blocks.** `transport http { tls }` on a single line is
a parse error. It is also redundant — an `https://` upstream enables TLS by
itself.

**Regional and global hostnames cannot share a site block.** A wildcard for
`repo.example.com` covers `repo.example.com` and `*.repo.example.com`, so
`dockerhub.repo.example.com` is in scope. It does **not** cover
`repo.eu-central.example.com` — a different name, not a subdomain. A `tls`
directive applies to every address on its block, so merging them serves the
regional names a certificate that does not match. Keep them in separate blocks.

**Do not remove the `header_up -X-Forwarded-*` lines.** Caddy logs
`Unnecessary header_up X-Forwarded-Proto` once per stripped route. That warning
is wrong: it matches the header name without noticing the leading `-` that makes
it a deletion. Verified against a controlled upstream that all three headers
arrive on an unmodified route and none arrives on a stripped one. Remove them
and `packages.buildkite.com` silently starts answering 301 to its marketing site
instead of the signed URL for its signing key.

**`docker compose up -d` does not apply a changed config file.** It recreates a
container when the *service definition* changes — image, environment, volume
list — not when the contents of a bind-mounted file change. A run that rewrites
only the Caddyfile brings up nothing and leaves the old config serving. The
script checksums both config files and reloads or restarts only what changed;
keep that if you touch this area.

**Stock `registry:2`/`registry:3` cannot proxy `public.ecr.aws`.** ECR Public
answers `HEAD` on a blob with 401 and the proxy HEADs every blob, so manifests
work and every blob fails
([distribution#4383](https://github.com/distribution/distribution/issues/4383)).
That's why registries run `REGISTRY_IMAGE` (`ghcr.io/glueops/registry`, upstream
plus that one fix). Don't switch back to a stock image until #4383 is fixed. Bump
`REGISTRY_IMAGE` by tag *and* digest together, and prefer a `v*` release tag.

**Keep `REGISTRY_PROXY_EXEC_COMMAND` and `REGISTRY_PROXY_TTL=0`.** Without a
credential helper the registry probes its upstream at startup and panics if it is
unreachable, so restarting during an upstream outage crash-loops. The helper must
be executable, or the registry silently pulls anonymously. The image deletes on
expiry (unlike `registry:2`), so a non-zero TTL removes cached manifests even
mid-outage. The script deletes `registry:2`'s old `scheduler-state.json`, whose
entries are all overdue.

**The image's default config is registry:3's development one** (debug logging, a
debug/pprof server on `:5001`). Keep the `REGISTRY_LOG_*` and
`REGISTRY_HTTP_DEBUG_ADDR` overrides.

**Helm and raw are nginx's, not Caddy's.** Caddy cannot cache, serve stale, or
rewrite a response body, which is why those ten routes go to nginx behind it.
Three settings there look optional and are not: `proxy_set_header
Accept-Encoding "";` (sub_filter cannot touch a gzipped body, and every chart
index serves gzip when asked), `proxy_buffer_size 32k` (GitHub's 302 carries a
signed URL that overflows the 4k default and fails as "upstream sent too big
header"), and `proxy_max_temp_file_size` being non-zero (nginx stages a response
in a temp file on its way into the cache).

**Docker Hub needs the `library/` rewrite.** Official images live under
`library/` and the docker daemon only adds that prefix when talking to Hub
directly, so a mirror hostname must rewrite single-segment repository names.
`OFFICIAL_NAMESPACE` is a separate table from `REGISTRIES` on purpose — the two
change for different reasons, and those records are colon separated while a URL
contains `://`, so a field added after the upstream gets a fragment of it.

**`set -e` and command substitution.** `local code` and `code="$(cmd)"` as
separate statements means the assignment carries the command's exit status, and
under `set -e` a failing probe kills the whole script silently. Write
`code="$(cmd)" || code="000"`.

**Debian lists index files it does not serve.** A `Release` file names
`main/binary-amd64/Packages` alongside `Packages.xz`, and only the compressed
one exists. A 404 on the bare name is correct upstream behaviour, not a mirror
fault.

**Ubuntu is amd64-only through `archive.ubuntu.com`.** arm64, ppc64el and s390x
live on `ports.ubuntu.com/ubuntu-ports`. Debian is unaffected — `deb.debian.org`
carries every architecture.

## Do not change client-facing URLs

`/repository/<name>/` is a Nexus path convention that `Remap` and `handle_path`
reproduce deliberately, so an existing estate can point at this installer
without editing a single `sources.list` or `helm repo add`. Renaming a
repository breaks every client silently — they get a 404, not an error that
explains itself.

## Adding a repository

See **Adding a repository** in `README.md`. The short version: each kind lives
in one table near the top of `install-mirror-stack.sh`, and APT additionally
needs a `Remap` line whose grouping decides whether the upstream's `pool/` is
shared or duplicated on disk.
