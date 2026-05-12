# Build & release notes

## Release artifact

Tarball name: `trino-server-<VERSION>-el9.tar.gz`.

Contents: the same `trino-server-<VERSION>/` tree as upstream Maven
Central, with `plugin/` filtered down to a curated set. See
`KEEP_PLUGINS` in `build/build-release.sh`.

The lab build is intentionally cache-bustable: re-running
`build-release.sh` with the same `TRINO_VERSION` re-downloads from Maven
Central, re-strips, and re-uploads with `--clobber`. The runtime image
build pins the tarball SHA via `RUNTIME_TARBALL_SHA256` so BuildKit
correctly invalidates when content changes under an unchanged URL.

## Plugin stripping rationale

Upstream `trino-server-466.tar.gz` is ~890 MB compressed. ~70% of that
is connectors we will not exercise in this POC (clickhouse, druid,
redshift, oracle, snowflake, cassandra, bigquery, kudu, mongodb, gcs,
etc.). Stripping drops the runtime tarball to ~200 MB, which:

- speeds on-prem image builds (less to curl / extract)
- reduces the runtime image size (less to pull when deploying)
- makes the surface area auditable -- only the connectors we ship are
  even *attempted* to be loaded at startup

Reintroducing a connector is a one-line change to `KEEP_PLUGINS`.

## Why not bake catalogs into the image?

Trino's `/etc/trino/catalog/*.properties` is environment-specific:

- Connection URLs (Lakekeeper in dev, Unity Catalog or Polaris on prem)
- Credentials (env-var refs or secret mounts)
- Warehouse paths (filesystem in dev, ADLS/S3 on prem)

Mounting the catalog dir at runtime keeps the image clean and reusable
across environments. The image ships a `memory.properties` only so the
container can answer `SELECT 1 FROM memory.information_schema.schemata`
without any external dependency.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Exception in thread "main" java.lang.NoClassDefFoundError: jdk/internal/...` | Wrong JVM. Image expects Java 21 (EL9 AppStream `java-21-openjdk-headless`). |
| `Caused by: java.lang.Error: required jvm option missing: --add-opens=java.base/...` | Edited `conf/jvm.config` and removed the `--add-opens` lines. Don't -- they're required on JDK 21+. |
| Runtime image build hits HTTP 404 on tarball | Release didn't publish or `TRINO_VERSION` mismatch. Check `gh release view trino-v<VERSION>-el9 --repo kingfadzi/trino-el9`. |
| `SHA256 mismatch` during image build | The release was re-uploaded with new content. Re-run `docker compose build --no-cache trino` or pass the new `RUNTIME_TARBALL_SHA256`. |
| Trino starts but `SELECT 1` times out | Discovery URI mismatch. `conf/config.properties` ships `discovery.uri=http://localhost:8080`; multi-node deployments need a real hostname. |
