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
| `test/` | the harness, its stubs, and one profile per service |
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
/opt/backend/adsu-team/bin/rollback.sh
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

Runs the harness against all five profiles: 63 assertions for team, 61 for the others (the
two-assertion gap is the smoke scenario, which only applies to a profile that defines
`SMOKE_PATH`). `self-test.yml` runs it on every pull request together with `shellcheck -x` and a
parse of the action manifests.

Run the matrix rather than one profile, and do not trust a green team run on its own. The first
generalisation left a literal `team.jar` in the line that saves the standby's previous build. On
the team profile that literal is indistinguishable from `$JAR_NAME`, so it passed; every other
service failed 25 assertions and would have destroyed its warm reserve on the first deploy. A
second profile is the cheapest thing that finds that class of bug, and there is no substitute
for it.
