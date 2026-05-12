# trino-el9

Prebuilt Trino server for AlmaLinux 9 / RHEL 9 / UBI 9. Companion to
`kingfadzi/cube-el9` and `kingfadzi/lightdash-el9` — same vendoring
pattern, same lab-builds-then-on-prem-curls flow.

## What this is

Two artifacts per release:

- A **stripped trino-server tarball** (Maven Central distribution minus
  the connectors we don't use in the open POC) published on a GitHub
  release as `trino-server-<VERSION>-el9.tar.gz`.
- A **slim Docker runtime image** (`Dockerfile.runtime`) that curls the
  tarball at build time and bakes a minimal Java 21 + Trino runtime onto
  a swappable EL9 base (`almalinux:9` in the lab; a RHEL/UBI 9 image from
  the internal registry on prem).

Catalogs are NOT baked into the image. The deploying compose (e.g.
`data-platform-bootstrap`) mounts its own `/etc/trino/catalog/` so the
same image can fly with iceberg+REST in dev, iceberg+UC on Databricks,
or anything else.

## Lab — cut a release

```bash
TRINO_VERSION=466 ./build/build-release.sh
```

Takes ~5 min (mostly the Maven Central download). Produces:

- GitHub release `trino-v466-el9` with `trino-server-466-el9.tar.gz` +
  `SHA256SUMS` -- this is what on-prem consumes.
- Image `docker.butterflycluster.com/trino/trino:466-el9` -- lab
  convenience.

Useful flags:

```bash
SKIP_STRIP=1   TRINO_VERSION=466 ./build/build-release.sh   # keep all plugins (~890MB)
SKIP_PUSH=1    TRINO_VERSION=466 ./build/build-release.sh   # build, no registry push
SKIP_RELEASE=1 TRINO_VERSION=466 ./build/build-release.sh   # build, no GH upload
```

## On prem — build runtime image

```bash
cp .env.example .env
$EDITOR .env                    # set RUNTIME_BASE_IMAGE to the on-prem UBI9 mirror
docker compose build trino
docker compose up -d trino
curl http://localhost:8080/v1/info | jq .
```

## Trino version

Pinned to **466** (LTS, runs on Java 21). Bump by changing `TRINO_VERSION`
in `.env` / build invocations -- not in the Dockerfile itself.

Why an LTS: Trino's main branch ships every 2-3 weeks. LTS releases get
security backports for ~6 months. Matches what Starburst typically tracks.

## File map

| Path                              | Purpose                                                                 |
|-----------------------------------|-------------------------------------------------------------------------|
| `Dockerfile.runtime`              | Lab + on-prem. Curls release tarball into a slim EL9 image.             |
| `build/build-release.sh`          | Lab. Downloads Maven Central, strips plugins, publishes GH release.     |
| `conf/`                           | Default config baked into the image (single-node, memory connector).    |
| `docker-compose.yml`              | Standalone Trino for smoke testing the image.                           |
| `BUILD.md`                        | Detailed build / release / troubleshoot notes.                          |

## Connectors retained when SKIP_STRIP=0

`iceberg`, `hive`, `jdbc`, `postgresql`, `memory`, `tpch`, `tpcds`,
`mysql`, `exchange-filesystem`, plus auth/resource-group/session
plugins. Anything else (clickhouse, druid, redshift, oracle, snowflake,
cassandra, bigquery, etc.) is dropped to shrink the tarball.

Need a dropped connector? Run with `SKIP_STRIP=1` to ship the full
tarball, or extend `KEEP_PLUGINS` in `build/build-release.sh`.
