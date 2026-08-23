#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
locked_source_ref="17395aabbeb1987898dca3a8e7ee1a720ceb2ccf"

# shellcheck source=../dependencies/xgc2-protobuf.env
source "${repo_root}/.xgc2/dependencies/xgc2-protobuf.env"
if [[ "${XGC2_PROTOBUF_STANDALONE_SOURCE_REF}" != "${locked_source_ref}" ]]; then
  echo "protobuf fetch test source lock is stale" >&2
  exit 1
fi

temporary="$(mktemp -d)"
cleanup() {
  rm -rf "${temporary}"
}
trap cleanup EXIT

mock_bin="${temporary}/bin"
mkdir -p "${mock_bin}"

cat > "${mock_bin}/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${MOCK_GH_LOG}"
printf '\n' >> "${MOCK_GH_LOG}"
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  printf '32658339664\t%s\n' "${MOCK_RUN_HEAD_SHA}"
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == *'/artifacts?per_page=100' ]]; then
  printf '9498077992\n'
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == *'/actions/artifacts/9498077992/zip' ]]; then
  printf 'mock artifact zip'
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
MOCK

cat > "${mock_bin}/unzip" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
destination=""
while (( $# > 0 )); do
  if [[ "$1" == "-d" ]]; then
    destination="$2"
    shift 2
  else
    shift
  fi
done
test -n "${destination}"
mkdir -p "${destination}"
: > "${destination}/xgc2-protobuf-dev_0.5.0-13~focal_amd64.deb"
MOCK

cat > "${mock_bin}/dpkg-deb" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "-f" ]]; then
  exit 1
fi
if [[ "${3:-}" == "Package" && $# -eq 3 ]]; then
  printf 'xgc2-protobuf-dev\n'
  exit 0
fi
printf 'Package: xgc2-protobuf-dev\nVersion: 0.5.0-13~focal\nArchitecture: amd64\n'
MOCK

chmod +x "${mock_bin}/gh" "${mock_bin}/unzip" "${mock_bin}/dpkg-deb"
export MOCK_GH_LOG="${temporary}/gh.log"

mismatch_output="${temporary}/mismatch"
if PATH="${mock_bin}:${PATH}" MOCK_RUN_HEAD_SHA="$(printf 'd%.0s' {1..40})" \
    "${repo_root}/.xgc2/scripts/fetch_protobuf_deb.sh" focal "${mismatch_output}" \
    > "${temporary}/mismatch.stdout" 2> "${temporary}/mismatch.stderr"; then
  echo "protobuf fetch accepted a successful run from the wrong head SHA" >&2
  exit 1
fi
grep -Fq "does not match locked source ${locked_source_ref}" "${temporary}/mismatch.stderr"
if grep -Fq '/actions/runs/' "${MOCK_GH_LOG}"; then
  echo "protobuf fetch inspected artifacts before validating the run head SHA" >&2
  exit 1
fi

: > "${MOCK_GH_LOG}"
success_output="${temporary}/success"
PATH="${mock_bin}:${PATH}" MOCK_RUN_HEAD_SHA="${locked_source_ref}" \
  "${repo_root}/.xgc2/scripts/fetch_protobuf_deb.sh" focal "${success_output}" \
  > "${temporary}/success.stdout"

test -f "${success_output}/xgc2-protobuf-dev_0.5.0-13~focal_amd64.deb"
grep -Fq -- "--commit ${locked_source_ref}" "${MOCK_GH_LOG}"
grep -Fq -- '--event push' "${MOCK_GH_LOG}"
grep -Fq -- '--status success' "${MOCK_GH_LOG}"
grep -Fq -- '--json databaseId\,headSha' "${MOCK_GH_LOG}"
grep -Fq "run 32658339664 at ${locked_source_ref}" "${temporary}/success.stdout"

echo "Pinned protobuf artifact fetch tests passed."
