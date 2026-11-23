#!/usr/bin/env bash
# Runs the generated apt-upstream helper against the generated apt-nginx.conf in
# a --network none container, the way an operator would use it on a host.
# Needs docker and passwordless sudo (the helper refuses to run as non-root).
#
#   ci/test-apt-upstream.sh <STACK_DIR of a DRY_RUN=1 install>
set -euo pipefail

d="$(cd "$1" && pwd)"
helper="${d}/apt-upstream"
state="${d}/apt-offline"
out="$(mktemp)"
img="$(awk '$1 == "image:" && $2 ~ /^nginx:/ {print $2; exit}' "${d}/docker-compose.yml")"

fail(){ echo "FAIL: $*" >&2; [[ -s "${out}" ]] && sed 's/^/  | /' "${out}" >&2; exit 1; }
# The helper only knows the name apt-nginx; never remove one this script didn't start.
ours(){ [[ "$(docker inspect -f '{{index .Config.Labels "apt-upstream-test"}}' apt-nginx 2>/dev/null)" == 1 ]]; }
if docker inspect apt-nginx >/dev/null 2>&1 && ! ours; then
  echo "FAIL: a container named apt-nginx already exists and isn't this test's" >&2; exit 1
fi
cleanup(){
  ours && docker rm -f apt-nginx >/dev/null 2>&1
  sudo find "${state}" -mindepth 1 -delete 2>/dev/null
  rm -f "${out}"
}
trap cleanup EXIT

start(){ # extra docker run args
  ours && docker rm -f apt-nginx >/dev/null 2>&1
  docker run -d --name apt-nginx --label apt-upstream-test=1 --network none \
    -v "${d}/apt-nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "${d}/apt-nginx-cache:/var/cache/apt-nginx" "$@" "${img}" >/dev/null
  # --network none: the runner can't reach it, so ask from inside.
  for _ in $(seq 1 30); do
    docker exec apt-nginx curl -sf http://127.0.0.1:3142/healthz >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "apt-nginx did not answer /healthz"
}

# apt-upstream exits with the wanted code; its output lands in ${out}.
expect(){ # want, args...
  local want="$1" rc=0; shift
  # shellcheck disable=SC2024 # the output file is the runner's, not root's
  sudo "${helper}" "$@" >"${out}" 2>&1 || rc=$?
  [[ "${rc}" == "${want}" ]] || fail "apt-upstream $*: exit ${rc}, want ${want}"
}
has(){ grep -qE -- "$1" "${out}" || fail "output lacks /$1/"; }
lacks(){ ! grep -qE -- "$1" "${out}" || fail "output has /$1/"; }
offline_header(){ # fetch-tier path
  local h
  h="$(docker exec apt-nginx curl -sI -m 5 "http://127.0.0.1:8091$1" 2>/dev/null | tr -d '\r')" || h=""
  grep -qi '^x-apt-offline: *1$' <<<"${h}"
}
state_empty(){ [[ -z "$(ls -A "${state}")" ]]; }

test -x "${helper}" || fail "helper is not executable"
n_hosts="$(sed -n 's/^HOSTS=(\(.*\) )$/\1/p' "${helper}" | wc -w)"

start -v "${state}:/etc/nginx/apt-offline:ro"

# Non-root: help works, everything else refuses without writing anything.
"${helper}" help >"${out}" 2>&1 || fail "help as non-root"
has 'archive\.ubuntu\.com +ubuntu-jammy'
rc=0; "${helper}" offline archive.ubuntu.com >"${out}" 2>&1 || rc=$?
[[ "${rc}" == 2 ]] || fail "offline as non-root: exit ${rc}, want 2"
has 'run: sudo apt-upstream offline archive\.ubuntu\.com'

# Usage errors write nothing.
expect 2 offline nope.example.com
expect 2 offline ubuntu-noble
has 'served|serves'
expect 2 offline --reason slow archive.ubuntu.com
has 'goes after'
expect 2 offline archive.ubuntu.com --reason
expect 2 offline archive.ubuntu.com extra
expect 2 status extra
state_empty || fail "a usage error wrote state"

# The reason is display text: quotes, backslashes and control characters are dropped.
expect 0 offline security.ubuntu.com --reason "$(printf 'say "hi"\\\tnow')"
expect 0 status
has '^security\.ubuntu\.com +offline .* say hinow$'
expect 0 online security.ubuntu.com

# Offline: verified, and only indexes for that host are switched.
expect 0 offline archive.ubuntu.com --reason "slow upstream (14 KB/s); see #42"
has 'archive\.ubuntu\.com OFFLINE \(verified\)$'
offline_header /idx/archive.ubuntu.com/ || fail "no X-Apt-Offline for the offline host"
! offline_header /idx/security.ubuntu.com/ || fail "X-Apt-Offline for an online host"
! offline_header /archive.ubuntu.com/ubuntu/pool/main/c/curl/curl.deb || fail "the switch answered a package path"
code="$(docker exec apt-nginx curl -s -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:3142/repository/ubuntu-noble/dists/noble/InRelease)"
[[ "${code}" == 503 ]] || fail "never-cached index for an offline host: ${code}, want 503"

# Repeating offline keeps the original time; status and --warn report it.
sudo touch -d '-1 hour' "${state}/archive.ubuntu.com"
before="$(stat -c %Y "${state}/archive.ubuntu.com")"
expect 0 offline archive.ubuntu.com
has 'already offline'
[[ "$(stat -c %Y "${state}/archive.ubuntu.com")" == "${before}" ]] || fail "repeat offline changed the time"
expect 0 status
has '^archive\.ubuntu\.com +offline .*slow upstream \(14 KB/s\); see #42'
lacks 'SWITCH INACTIVE'
expect 0 status --warn
[[ "$(grep -c '^WARNING: repo\.example\.com: apt upstream archive' "${out}")" == 1 ]] || fail "status --warn: want one WARNING line naming the region"

# all: every host verified, including the one already offline; online all clears.
expect 0 offline all
[[ "$(grep -c 'OFFLINE (verified)$' "${out}")" == "${n_hosts}" ]] || fail "offline all: want ${n_hosts} verified lines"
sudo grep -q 'slow upstream' "${state}/archive.ubuntu.com" || fail "offline all replaced an existing reason"
expect 0 online all
state_empty || fail "online all left state behind"
expect 0 online archive.ubuntu.com

# Rollback shape: an apt-nginx without the mount ignores the files.
expect 0 offline archive.ubuntu.com
start
expect 0 status
has 'SWITCH INACTIVE'
expect 4 offline security.ubuntu.com
has 'not visible to nginx'

# Stopped: the file is written and takes effect at the next start.
docker stop apt-nginx >/dev/null
expect 4 offline deb.debian.org
has 'apt-nginx is exited'
[[ -f "${state}/deb.debian.org" ]] || fail "offline while stopped did not keep the file"
expect 0 status
has 'apt-nginx is exited'

expect 0 online all
echo "apt-upstream: all checks passed"
