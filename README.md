# deploy-kit

One implementation of the blue-green deploy shared by five backends — adsu-sso, adsu-team,
adsu-ai, status-monitor and adsu-student-core — instead of five copies that drift apart.

The copies did drift. Only team-backend ever received the fixes that matter: reading the active
colour from the live Caddy upstream rather than the stale `active` file, gating on the readiness
group rather than the aggregate health, verifying that the build answering on the standby port
really is this release, and restoring the standby's previous jar when a new build fails to start.
Adopting the kit is how the other four get all of that at once.

## What is in here

| path | what |
|---|---|
| `lib/` | `deploy.sh`, `rollback.sh`, `release.sh` and the shared `lib.sh` |
| `gradle-build/` | composite action: wrapper validation, JDK, cache, `./gradlew …` |
| `lockstep-check/` | composite action: a shared-kernel pin must equal the latest release |
| `blue-green/` | composite action: roll into standby, gate, switch Caddy, write the summary |
| `test/` | the harness, its stubs, and one profile per profile *shape* |
| `service.conf.example` | the profile a service repository copies and fills in |

They are composite actions, not reusable workflows, on purpose. A composite action runs as steps
inside the caller's job: no second runner slot on the production host, no separately rounded
billing minute, the same workspace as the build step before it. And it leaves `runs-on`, `if:`,
`concurrency` and `permissions` with the caller — which is exactly where they belong, since those
are the parts that genuinely differ per service.

## Adopting it in a service repository

**1. Write `deploy/service.conf`** — copy `service.conf.example` and fill in the nine values. Nine
is the whole difference between the five services.

**2. CI** — one job, two or three steps:

```yaml
- uses: actions/checkout@v4
- uses: LDS-ADSU/deploy-kit/lockstep-check@v1.0.0   # only where a shared kernel is pinned
  with:
    artifact: ru.adygnet:studlife-core
    repository: LDS-ADSU/studlife-core
    token: ${{ secrets.PACKAGES_READ_TOKEN || secrets.GITHUB_TOKEN }}
- uses: LDS-ADSU/deploy-kit/gradle-build@v1.0.0
  with:
    gradle-args: build
    packages-token: ${{ secrets.PACKAGES_READ_TOKEN || secrets.GITHUB_TOKEN }}
    upload-reports: 'true'
```

**3. Deploy** — build with the JDK already on the host, then hand the jar to the kit:

```yaml
- uses: actions/checkout@v4
  with: { ref: "${{ github.event.workflow_run.head_sha || github.sha }}" }
- uses: LDS-ADSU/deploy-kit/gradle-build@v1.0.0
  with:
    gradle-args: clean bootJar -x test
    setup-java: 'false'      # the JDK that runs the service is the one to build with
    cache: 'false'           # ~/.gradle already survives on a persistent runner
- uses: LDS-ADSU/deploy-kit/blue-green@v1.0.0
  with:
    profile: deploy/service.conf
    release-id: ${{ github.event.workflow_run.head_sha || github.sha }}
```

Pin an exact tag, never a floating `@v1`: otherwise someone else's merge into this repository
changes how your production deploy behaves with no commit in yours. Dependabot's `github-actions`
ecosystem opens the bump PRs, so the cost of pinning exactly is close to zero.

## Rolling back

Every successful deploy installs the scripts and the resolved profile into `$DEPLOY_DIR/bin`, so
the on-call path never depends on where the runner unpacked an action checkout:

```bash
/opt/backend/<service>/bin/rollback.sh
```

It needs no environment at all — `lib.sh` finds the `service.conf` sitting next to it. Rollback
goes exactly one colour back; once two deploys have landed, both colours carry new code and you
want `bin/release.sh --list` followed by `bin/release.sh <release-id>`.

Installation happens **only after a successful switch**. A build that failed its gates has not
vouched for its scripts either, so `bin/` always holds the last known-good copy, which is also
the one matching the release currently serving traffic.

## Changing anything here

```bash
test/matrix.sh
```

Runs the harness against every profile in `test/profiles/`: 63 assertions where the profile has
a smoke endpoint, 61 where it does not. `self-test.yml` runs it on every pull request together
with `shellcheck -x` and a parse of the action manifests.

The fixtures are **synthetic and organised by shape**, not copies of production profiles. The
harness asserts which fields are present and how they combine, never a particular port number, so
real topology would add nothing here — and the shapes can cover more than production does. The
five-digit-port fixture matches no current service precisely because every real profile is
four-digit: without it, the 2-5 digit width in `detect_active` would be asserted by nothing, and
the first service to pick a high port would fail with "cannot determine the active colour" on a
perfectly healthy host.

Run the matrix, never a single profile. The first generalisation left a literal `team.jar` in the
line that saves the standby's previous build; on the profile it was written for, that literal is
indistinguishable from `$JAR_NAME`, so it passed, while every other shape failed 25 assertions and
would have destroyed the warm reserve on the first deploy. The synthetic fixtures caught a second
one immediately: the harness hardcoded `407` as a successful probe response — one service's
value — and a profile accepting only `200` failed its own happy path. A second profile is the
cheapest thing that finds this class of bug, and nothing substitutes for it.
