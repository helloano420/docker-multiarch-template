# docker-multiarch-template

Reusable GitHub Actions workflow that builds a Dockerfile **once per target
platform on native runners**, then assembles a single multi-arch manifest list
and publishes it to a container registry (GitHub Packages / GHCR by default).

Single source of truth for "build a multi-arch image and publish it" across
projects: every repository calls the same workflow, so caching, tagging, SBOM,
provenance and verification behave identically everywhere.

- Reusable workflow: [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
- Live example: [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (this repo publishes its own example image)

## Quick start

Add one file, `.github/workflows/docker-publish.yml` in **your** repository:

```yaml
name: docker-publish

on:
  workflow_dispatch:
  pull_request:
  push:
    branches: [main]
    tags: ['v*']

concurrency:
  group: docker-publish-${{ github.ref }}
  cancel-in-progress: true

jobs:
  publish:
    uses: NextGenContributions/docker-multiarch-template/.github/workflows/docker-publish.yml@v1
    permissions:
      contents: read
      packages: write
    with:
      push: ${{ github.event_name != 'pull_request' }}
```

That publishes `ghcr.io/<your-owner>/<your-repo>` for `linux/amd64` and
`linux/arm64`. Everything else has a sane default; override only what you need.

> The `permissions:` block at the caller is mandatory. A reusable workflow can
> only ever *narrow* the token it receives, never widen it, so `packages: write`
> must be granted by the caller or the push step fails with `denied`.

## How it works

```
prepare (ubuntu-latest)
  ├─ lowercase image name
  ├─ docker/metadata-action  → tags, labels, version
  └─ platforms "linux/amd64,linux/arm64" → build matrix
        │
        ├──────────────┬───────────────────────────┐
        ▼              ▼                           ▼
   build linux/amd64   build linux/arm64        (build linux/arm/v7 …)
   ubuntu-24.04        ubuntu-24.04-arm
   push-by-digest      push-by-digest
        │              │
        └──────┬───────┘
               ▼
   merge (ubuntu-latest)
     ├─ download digests (artifacts)
     ├─ buildx imagetools create -t <tags> img@sha256:… img@sha256:…
     ├─ assert every requested platform is present
     └─ job summary: digest + tags
```

Each platform is built on a runner of its own CPU architecture, pushed as an
untagged digest, and the manifest list is assembled from those digests. Nothing
is rebuilt at merge time.

### Why not one job with `platforms: linux/amd64,linux/arm64`?

That is the two-line version from the
[Docker docs](https://docs.docker.com/build/ci/github-actions/multi-platform/#with-qemu),
and it is fine for a toy image. For real images it means:

| | single job + QEMU | this workflow (native runners) |
| --- | --- | --- |
| arm64 execution | emulated on x86, 2-20x slower | native |
| parallelism | platforms built sequentially in one job | one job per platform, in parallel |
| failure blast radius | one flaky platform kills the whole build | `fail-fast: false`, only that platform |
| build cache | shared but contended | `type=gha` cache scoped per platform |
| wall clock | sum of all platforms | max of all platforms |

GitHub-hosted arm64 runners are free for public repositories
([changelog](https://github.blog/changelog/2025-08-07-arm64-hosted-runners-for-public-repositories-are-now-generally-available/)).
For **private** repos, `ubuntu-24.04-arm` needs a paid arm64 larger runner -
override `runner-arm64` in that case (or set it to `ubuntu-24.04` to fall back
to QEMU, which the workflow handles automatically via `setup-qemu-action`).

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `image` | `ghcr.io/<calling repo>` | Lowercase-normalised for you. Do not include a tag. |
| `dockerfile` | `Dockerfile` | Path relative to the repo root. |
| `context` | `.` | Build context. |
| `platforms` | `linux/amd64,linux/arm64` | `arm64` → arm runner, everything else → amd64 runner. Non-native platforms get QEMU automatically. |
| `registry` | `ghcr.io` | Registry for `docker/login-action`. Empty string skips login. |
| `push` | `true` | `false` builds and loads locally only (use on PRs). |
| `tags` | branch / PR / semver / `sha-` / `latest` on default branch | Any [metadata-action tag rule](https://github.com/docker/metadata-action#tags-input). |
| `labels` | `''` | Extra OCI labels, merged with the metadata defaults. |
| `build-args` | `''` | **Never put secrets here** - build args are recorded in provenance. |
| `target` | `''` | Dockerfile stage. |
| `test-command` | `''` | Shell run once per platform against the freshly built image. `$IMAGE`, `$PLATFORM`, `$EXPECTED_ARCH` (`amd64`, `arm64`, …) and `$EXPECTED_MACHINE` (`uname -m`) are exported. |
| `runner-amd64` | `ubuntu-24.04` | |
| `runner-arm64` | `ubuntu-24.04-arm` | |
| `cache-scope` | calling repository | Bump to force a cold build. |
| `provenance` | `mode=max` | Pushed to the registry as an attestation. |
| `sbom` | `true` | BuildKit SBOM attestation. |

Outputs: `image`, `tags`, `version` (metadata JSON), `digest` (merged manifest
list digest).

### Testing before publishing

`test-command` runs against a locally loaded copy of the image, on that
platform's native runner, before anything is merged. It is a separate
cache-warm build (same `type=gha` scope), so it costs a manifest write, not a
rebuild:

```yaml
    with:
      test-command: |
        set -euo pipefail
        # Fail if the image does not run natively on this runner.
        docker run --rm "$IMAGE" /usr/local/bin/my-healthcheck
```

For heavyweight integration tests, prefer a separate job that pulls the merged
manifest after `publish` finishes, and keep `test-command` as a smoke test.

## Tags

Defaults follow the
[metadata-action conventions](https://github.com/docker/metadata-action#tags-input):
`main` → `main`, `v1.2.3` → `1.2.3`, `1.2`, `latest`, PRs → `pr-42`, plus
`sha-<short>` on every build. `flavor: latest=false` is set so that `latest` is
only applied by the explicit `type=raw,value=latest,enable={{is_default_branch}}`
rule rather than automatically on every semver build.

Pinning consumers to a digest is still the only safe way to consume images:

```bash
docker buildx imagetools inspect ghcr.io/org/repo:latest
docker pull ghcr.io/org/repo@sha256:<manifest-list-digest>
```

## Reading and verifying what was published

```bash
# Platforms present in the manifest list
docker buildx imagetools inspect ghcr.io/org/repo:latest

# SBOM + provenance attestations attached to the image
docker buildx imagetools inspect ghcr.io/org/repo:latest --format '{{json .Manifest}}' | jq

# BuildKit attestation details
docker buildx imagetools inspect ghcr.io/org/repo:latest \
  --format '{{ range .Manifest.Manifests }}{{ .Platform.Architecture }} {{ end }}'
```

The `merge` job hard-fails if any requested platform is missing from the merged
manifest, so a "successful" run always means a genuinely multi-arch image.

## Pitfalls this template already handles

- **Registry paths must be lowercase.** Organisations like
  `NextGenContributions` produce `invalid reference format` otherwise; the
  `prepare` job lowercases the name once and every later stage uses it.
- **`push-by-digest` needs a non-default Buildx driver.** `setup-buildx-action`
  is required in both the build and merge jobs.
- **Artifact names must be unique per matrix leg.** Each platform uploads
  `digest-<os>-<arch>`, and the merge job downloads them with
  `pattern: digest-*` + `merge-multiple: true`.
- **`--provenance=mode=max` on a public repo records build args.** Use
  `RUN --mount=type=secret` for credentials, never `build-args`.
- **`load: true` cannot be combined with multi-platform or attestations.** That
  is why PR builds (single platform, `push: false`) load locally and published
  builds push by digest.
- **`fail-fast: false`** so one broken architecture does not cancel the other.

## Alternatives worth knowing

- [`docker/github-builder`](https://github.com/docker/github-builder) - official
  Docker-maintained reusable workflow that does the same distribute-then-merge
  dance, plus signed SLSA provenance and signed GHA cache. If you are happy
  delegating build logic to the `docker` org, it is the lowest-maintenance
  option and a drop-in replacement for the job in this template. This template
  exists because we want to own the workflow, keep it dependency-free, and pin
  every action ourselves.
- [Bake](https://docs.docker.com/build/building/multi-platform/#bake) - worth
  adopting when you have several images, matrix builds, or want the build
  definition in version-controlled HCL/JSON instead of workflow YAML.
- [Multi-platform build docs](https://docs.docker.com/build/ci/github-actions/multi-platform/)
  and [attestations docs](https://docs.docker.com/build/ci/github-actions/attestations/).

## Repository as a template

This repository is marked as a GitHub template repository:

```bash
gh repo create <owner>/<new-repo> \
  --template NextGenContributions/docker-multiarch-template \
  --public --clone
```

Delete `Dockerfile`, `hello.sh` and `.github/workflows/ci.yml` from the copy,
then wire up your own caller workflow.

## Versioning

Reference the workflow by a moving major tag (`@v1`) for convenience, or by a
full commit SHA when you need an immutable pin:

```yaml
uses: NextGenContributions/docker-multiarch-template/.github/workflows/docker-publish.yml@<sha>
```

## License

[MIT](LICENSE)
