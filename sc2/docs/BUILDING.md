# Building SC2 from source

This repository holds **only source**. The large offline payload — RPM
closures, container images, and bundle `copy` artifacts — is **not** committed;
it is fetched fresh at build time from the locations declared in
[`build.conf`](../build.conf). This keeps the repo small enough for GitHub and
makes every artifact's origin explicit and reproducible.

## The flow

```
git clone <repo>            # source only (a few hundred KB)
cd sc2
# 1. choose/point sources in build.conf (profile: public or work)
SC2_PROFILE=public build/fetch-artifacts.sh
# 2. package
build/build-bundle.sh       # -> dist/sc2-<version>-x86_64.tgz (+ .sha256)
```

`build/build-bundle.sh --fetch` does both. `build/fetch-artifacts.sh --dry-run`
shows what would be pulled without doing it.

## build.conf

`build.conf` is the single source of truth for the payload:

- `SC2_MAJORS` and `RPMS_EL{7,8,9,10}` — which RHEL majors to build RPM closures
  for and the top-level packages each needs (deps are resolved automatically).
- `IMAGES` — container images to bake in: `ref | dest-archive | save-tag`. The
  `save-tag` must match the image name in the app's `docker-compose.yml`.
- `ARTIFACTS` — `copy` payloads: `source | dest-under-artifacts` (source may be
  `file://`, `https://`, or a GitLab generic-package URL).
- Profiles set the fetch endpoints:
  - **public** — CentOS 7 vault + docker-ce repo, UBI images, `docker.io`.
    Builds from a plain internet-connected machine.
  - **work** — internal RHEL mirror (`SC2_RPM_MIRROR_BASE`) + internal container
    registry (`SC2_IMAGE_REGISTRY`) + base images that expose the full RHEL
    repos. Fill in the placeholders, or set them via env / CI variables.

Select with `SC2_PROFILE=public|work` (default `public`).

## Requirements

- **Fetch**: bash, curl, tar, and podman or docker (RPM closures build inside
  containers; images are pulled and `save`d).
- **Package**: bash + tar only; runs fully offline.

See [`BUNDLING.md`](BUNDLING.md) for RPM-closure caveats (resolve against the
oldest minor you support; UBI lacks `container-selinux` — use the `work`
profile or a subscribed base for a complete el8/el9 closure).

## GitLab CI

[`.gitlab-ci.yml`](../../.gitlab-ci.yml) (at the repo root) runs three stages
with `SC2_PROFILE=work`:

1. **fetch** — `build/fetch-artifacts.sh` against the internal mirror/registry.
2. **build** — `build/build-bundle.sh` → the bundle as a job artifact.
3. **publish** — on a git tag, uploads `sc2-<ver>-x86_64.tgz` (and its
   `.sha256`) to this project's **generic Package Registry** at
   `…/packages/generic/sc2/<ver>/`.

Configure these under **Settings → CI/CD → Variables**:

| Variable | Purpose |
|---|---|
| `SC2_IMAGE_REGISTRY` | internal registry mirroring `library/*` images |
| `SC2_RPM_MIRROR_BASE` | internal yum/dnf mirror base (`/el<major>` appended) |
| `SC2_BASEIMG_EL7..10` | base images exposing full RHEL repos (optional) |

`CI_JOB_TOKEN` (automatic) authenticates the package upload. Cut a release by
bumping `VERSION`, committing, and pushing a tag (e.g. `git tag v0.7.0 && git
push --tags`).
