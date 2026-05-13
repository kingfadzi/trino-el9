#!/usr/bin/env bash
#
# Lab-side build & release script for trino-el9.
#
# Unlike cube-el9, there is no compile step -- Trino ships as a ready-to-run
# JVM tarball from Maven Central. The lab's job is to:
#   1. download trino-server-<version>.tar.gz from Maven Central
#   2. (optionally) strip unused connector plugins to slim the runtime
#   3. repackage as trino-server-<version>-el9.tar.gz with our SHA256
#   4. publish the release on GitHub
#   5. (optionally) build & push the runtime image
#
# Required:
#   TRINO_VERSION         Trino release (e.g. 466). Required.
#   gh CLI on PATH; GitHub PAT in GITHUB_API_TOKEN (or GH_TOKEN / GITHUB_TOKEN)
#                         with `repo` scope.
#   docker logged in to $REGISTRY (SKIP_PUSH=1 to bypass).
#
# Optional env (defaults shown):
#   GH_REPO=kingfadzi/trino-el9
#   REGISTRY=docker.butterflycluster.com
#   REGISTRY_IMAGE=${REGISTRY}/trino/trino
#   RUNTIME_BASE_IMAGE=docker.butterflycluster.com/builder-images/almalinux9-base:9
#   MAVEN_BASE_URL=https://repo1.maven.org/maven2
#   SKIP_STRIP=0          # set to 1 to skip plugin stripping (full ~890MB tarball)
#   SKIP_PUSH=0           # set to 1 to skip docker push
#   SKIP_RELEASE=0        # set to 1 to skip gh release upload
#   AUTO_INIT_REPO=1      # 0 to fail instead of seeding empty repo
#
# Plugins kept when SKIP_STRIP=0 (must match the catalogs we deploy):
#   - iceberg              (curated layer storage)
#   - hive                 (refined-layer parquet reads, on-disk)
#   - jdbc                 (jdbc catalog backend; postgres connector for refs)
#   - postgresql           (for joining curated tables with postgres metadata)
#   - memory               (smoke tests)
#   - tpch, tpcds          (built-in benchmark / demo data)
#   - mysql                (kept tiny -- common BI dialect for ad-hoc reads)
#   - exchange-filesystem  (required by every query plan)
#   - password-authenticator-* and resource-group-* (security, small)
#
# Everything else (clickhouse, druid, redshift, oracle, snowflake, cassandra,
# bigquery, gcs, googlesheets, kudu, etc.) is dropped.

set -euo pipefail

# --- env / defaults ---------------------------------------------------------

: "${TRINO_VERSION:?TRINO_VERSION is required (e.g. 466)}"
: "${GH_REPO:=kingfadzi/trino-el9}"
: "${REGISTRY:=docker.butterflycluster.com}"
: "${REGISTRY_IMAGE:=${REGISTRY}/trino/trino}"
: "${RUNTIME_BASE_IMAGE:=almalinux:9}"
: "${MAVEN_BASE_URL:=https://repo1.maven.org/maven2}"
: "${SKIP_STRIP:=0}"
: "${SKIP_PUSH:=0}"
: "${SKIP_RELEASE:=0}"
: "${AUTO_INIT_REPO:=1}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${REPO_ROOT}/dist"

TAG="trino-v${TRINO_VERSION}-el9"
UPSTREAM_TAR="trino-server-${TRINO_VERSION}.tar.gz"
RUNTIME_TAR="trino-server-${TRINO_VERSION}-el9.tar.gz"
RUNTIME_IMAGE_TAG="${REGISTRY_IMAGE}:${TRINO_VERSION}-el9"
RELEASE_BASE_URL="https://github.com/${GH_REPO}/releases/download"

# Connectors / event listeners to keep. Anything in plugin/ NOT matching
# one of these is removed.
KEEP_PLUGINS=(
  iceberg
  hive
  jdbc
  postgresql
  memory
  tpch
  tpcds
  mysql
  exchange-filesystem
  password-authenticators
  resource-group-managers
  session-property-managers
  http-server
  http-event-listener
  # OpenLineage event listener. Emits an event per Trino query so dbt
  # model runs, Lightdash chart loads, Cube semantic queries all show
  # up in the lineage graph. The plugin dir bundles 53 transitive-dep
  # jars (~24MB) because Maven Central publishes only the main jar
  # without its deps. Trino's tarball uses hardlinks across plugins
  # for dedupe; the strip pass below preserves them because we extract
  # the whole tree and only delete unwanted dirs.
  openlineage
)

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

# --- preflight --------------------------------------------------------------

say "[0/5] Preflight"

[ -f "$REPO_ROOT/Dockerfile.runtime" ] || die "missing $REPO_ROOT/Dockerfile.runtime"
command -v curl >/dev/null               || die "curl not on PATH"
command -v tar >/dev/null                || die "tar not on PATH"

if [ "$SKIP_RELEASE" != "1" ]; then
  command -v gh >/dev/null || die "gh CLI not on PATH (install or set SKIP_RELEASE=1)"
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_API_TOKEN:-${GITHUB_TOKEN:-}}}"
  [ -n "$GH_TOKEN" ] || die "no GitHub token (set GITHUB_API_TOKEN, GH_TOKEN, or GITHUB_TOKEN)"

  if ! gh repo view "$GH_REPO" --json name >/dev/null 2>&1; then
    die "repo $GH_REPO not found or not accessible with this token"
  fi
  if ! gh api "/repos/${GH_REPO}/commits?per_page=1" >/dev/null 2>&1; then
    if [ "$AUTO_INIT_REPO" = "1" ]; then
      say "    repo $GH_REPO is empty, seeding with README to enable releases"
      readme=$(printf '# %s\n\nPrebuilt Trino server for AlmaLinux 9 / RHEL 9. Releases are produced by build/build-release.sh.\n' "${GH_REPO##*/}" | base64 -w0)
      gh api -X PUT "/repos/${GH_REPO}/contents/README.md" \
        -f message="init: seed repo so releases can be created" \
        -f content="$readme" >/dev/null
    else
      die "repo $GH_REPO is empty -- seed it or set AUTO_INIT_REPO=1"
    fi
  fi
fi

if [ "$SKIP_PUSH" != "1" ]; then
  reg_host="${REGISTRY_IMAGE%%/*}"
  if ! docker pull --quiet "${reg_host}/__preflight_does_not_exist__:nope" 2>&1 \
      | grep -qE "manifest unknown|not found|denied|repository does not exist"; then
    :
  fi
fi

# --- prepare dist -----------------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST"

# --- download upstream tarball ----------------------------------------------

say "[1/5] Downloading trino-server-${TRINO_VERSION} from Maven Central"
UPSTREAM_URL="${MAVEN_BASE_URL}/io/trino/trino-server/${TRINO_VERSION}/${UPSTREAM_TAR}"
curl -fsSL --progress-bar "${UPSTREAM_URL}" -o "${DIST}/${UPSTREAM_TAR}"

# Verify against upstream sha512 if possible.
if curl -fsSL "${UPSTREAM_URL}.sha512" -o "${DIST}/${UPSTREAM_TAR}.sha512" 2>/dev/null; then
  EXPECTED=$(awk '{print $1}' "${DIST}/${UPSTREAM_TAR}.sha512")
  ACTUAL=$(sha512sum "${DIST}/${UPSTREAM_TAR}" | awk '{print $1}')
  [ "$EXPECTED" = "$ACTUAL" ] || die "sha512 mismatch on upstream tarball"
  say "    upstream sha512 verified"
fi

# --- strip + repackage ------------------------------------------------------

if [ "$SKIP_STRIP" = "1" ]; then
  say "[2/5] SKIP_STRIP=1 -- renaming upstream tarball as-is"
  mv "${DIST}/${UPSTREAM_TAR}" "${DIST}/${RUNTIME_TAR}"
else
  say "[2/5] Stripping unused plugins from trino-server-${TRINO_VERSION}"
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  tar -xzf "${DIST}/${UPSTREAM_TAR}" -C "$STAGE"

  PLUGIN_DIR="$STAGE/trino-server-${TRINO_VERSION}/plugin"
  [ -d "$PLUGIN_DIR" ] || die "plugin/ not found in extracted tarball"

  # shellcheck disable=SC2207
  ALL_PLUGINS=( $(cd "$PLUGIN_DIR" && ls -1) )
  for p in "${ALL_PLUGINS[@]}"; do
    keep=0
    for k in "${KEEP_PLUGINS[@]}"; do
      if [ "$p" = "$k" ]; then keep=1; break; fi
    done
    if [ "$keep" = "0" ]; then
      rm -rf "$PLUGIN_DIR/$p"
    fi
  done

  say "    plugins retained: $(cd "$PLUGIN_DIR" && ls -1 | tr '\n' ' ')"
  ( cd "$STAGE" && tar -czf "${DIST}/${RUNTIME_TAR}" "trino-server-${TRINO_VERSION}" )
  rm -rf "$STAGE"
fi

ORIG_SIZE=$(du -h "${DIST}/${UPSTREAM_TAR}" 2>/dev/null | cut -f1 || echo unknown)
NEW_SIZE=$(du -h "${DIST}/${RUNTIME_TAR}" | cut -f1)
say "    size: upstream ${ORIG_SIZE} -> packaged ${NEW_SIZE}"
rm -f "${DIST}/${UPSTREAM_TAR}" "${DIST}/${UPSTREAM_TAR}.sha512"

# --- SHA256 -----------------------------------------------------------------

say "[3/5] Generating SHA256SUMS"
( cd "$DIST" && sha256sum "$RUNTIME_TAR" > SHA256SUMS )
cat "${DIST}/SHA256SUMS"

# --- release ----------------------------------------------------------------

if [ "$SKIP_RELEASE" = "1" ]; then
  say "[4/5] SKIP_RELEASE=1, skipping gh release upload"
else
  say "[4/5] Publishing GitHub release $TAG to $GH_REPO"
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "    release $TAG exists, reusing"
  else
    gh release create "$TAG" \
      --repo "$GH_REPO" \
      --title "Trino ${TRINO_VERSION} (EL9 prebuilt)" \
      --notes "Prebuilt trino-server ${TRINO_VERSION} (Maven Central, plugin-stripped for the open POC). Binary-compatible with AlmaLinux 9 / RHEL 9."
  fi
  gh release upload "$TAG" \
    --repo "$GH_REPO" \
    --clobber \
    "$DIST/$RUNTIME_TAR" \
    "$DIST/SHA256SUMS"
fi

# --- runtime image ----------------------------------------------------------

say "[5/5] Building runtime image $RUNTIME_IMAGE_TAG (pulls from $RELEASE_BASE_URL)"
TARBALL_SHA256=$(awk -v t="$RUNTIME_TAR" '$2 == t {print $1}' "$DIST/SHA256SUMS")
[ -n "$TARBALL_SHA256" ] || die "could not extract sha for $RUNTIME_TAR from SHA256SUMS"
docker build \
  -f "$REPO_ROOT/Dockerfile.runtime" \
  --build-arg RUNTIME_BASE_IMAGE="$RUNTIME_BASE_IMAGE" \
  --build-arg TRINO_VERSION="$TRINO_VERSION" \
  --build-arg RELEASE_BASE_URL="$RELEASE_BASE_URL" \
  --build-arg RUNTIME_TARBALL_SHA256="$TARBALL_SHA256" \
  -t "$RUNTIME_IMAGE_TAG" \
  "$REPO_ROOT"

if [ "$SKIP_PUSH" = "1" ]; then
  say "SKIP_PUSH=1, skipping docker push"
else
  say "Pushing $RUNTIME_IMAGE_TAG"
  docker push "$RUNTIME_IMAGE_TAG"
fi

say "Done."
echo "    Release : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "    Image   : ${RUNTIME_IMAGE_TAG}"
