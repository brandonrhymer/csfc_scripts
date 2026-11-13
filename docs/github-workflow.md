# Working in GitHub

## Track a bounded result

Use Issues for defects and script requests, with synthetic examples and explicit
acceptance evidence. A milestone groups a deliverable; the Project shows its
status and priority. Link the implementation PR to its issue and keep unresolved
validation visible. Changes to repository settings and project automation are
separate from files committed here.

Use the [project board](https://github.com/users/brandonrhymer/projects/3) and
[repository milestones](https://github.com/brandonrhymer/csfc_scripts/milestones)
for the current work sequence. Workflow foundations are tracked in
[#13](https://github.com/brandonrhymer/csfc_scripts/issues/13); shared navigation
and validation coverage are tracked in
[#11](https://github.com/brandonrhymer/csfc_scripts/issues/11). Product packaging
and releases are tracked in
[#31](https://github.com/brandonrhymer/csfc_scripts/issues/31); live lab validation
remains deferred in [#29](https://github.com/brandonrhymer/csfc_scripts/issues/29).

Keep versioned operator instructions beside scripts. The Wiki can provide
orientation and links to those runbooks; it should not maintain a second copy of
parameters, safety requirements or validation claims.

## Automated checks

The [Offline validation workflow](../.github/workflows/ci.yml) runs on pull
requests, pushes to `main`, manual dispatch, and calls from release preparation.
Its job names are:

| Check | Environment | Scope |
| --- | --- | --- |
| Linux offline checks | Ubuntu 24.04, Python 3, Bash and PowerShell 7.4+ | Discovers all `tests/test_*.py` suites; sanitizer regressions including Unix permissions |
| Windows offline checks | Windows Server 2022; Windows PowerShell 5.1 and PowerShell 7.4+ | Parser/Defender helpers, MECM mocks, sanitizer regressions |
| KRBTGT offline release gates | Windows Server 2022; Windows PowerShell 5.1 | Committed hashes, parser, analyzer and mocked Pester suite |
| Product package checks | Windows Server 2022; Bun 1.4.2 | Packaging tests, product version checks, committed-source ZIPs and bundle, archive verification and extraction checks |

The tests use synthetic inputs and do not contact operational targets. Hosted
runner setup is network-connected: checkout retrieves source and the KRBTGT job
installs missing Pester 3.4.0 and PSScriptAnalyzer 1.25.0 development dependencies
from PowerShell Gallery. The package job installs Bun 1.4.2 for build-time use.
These development dependencies are not operator runtime requirements.
The workflow uses a read-only contents token, disables checkout credential
persistence and pins actions to full commit SHAs. Dependabot proposes weekly
GitHub Actions dependency updates; review those PRs before merging.

On pull requests and `main`, **Product package checks** produces all 16 product
ZIPs plus a bundle in the `product-packages` Actions artifact, retained for 14
days. Packages include declared dependencies and runbooks. Download and inspect
these candidates using the [release guide](releases.md#candidate-builds).
The version check requires a strictly newer version for every changed product
payload and rejects downgrades. Shared packaged-document changes can affect
several products. Unrelated commits leave an unchanged product's ZIP stable.

The [validation matrix](validation.md#package-check-matrix) lists local commands
and evidence limits. The three existing offline jobs passed on the recorded
[baseline run](https://github.com/brandonrhymer/csfc_scripts/actions/runs/43473398355).
That result predates the packaging extension; use a successful run of the new
revision before claiming the package job passed or requiring it in repository
rules. Neither committed workflow files nor passing mocks prove lab readiness.

## Product releases and quarterly bundles

Each operational script has a catalog version and product release tag. The
[Prepare product release workflow](../.github/workflows/release.yml) accepts a
product ID or `bundle`, an optional bundle subset, and a bundle version. It runs
on `main`, reuses all validation at the same commit, verifies downloaded package
artifacts, generates provenance attestations and creates a draft GitHub Release.
Before creating the draft, it reserves the namespaced lightweight tag at the
tested SHA; after uploading assets, it verifies their hashes and the actual tag.
An interrupted run can leave a reserved tag or incomplete draft for maintainer
reconciliation. Existing tags and releases are not overwritten on retry.
Only the release-preparation job receives the write permissions needed for its
release and attestation operations; ordinary validation remains read-only.

A schedule prepares an all-product bundle draft at 14:00 UTC on January 1,
April 1, July 1 and October 1. Script changes do not trigger bundle releases.
The maintainer reviews and publishes each draft separately. This workflow
distributes packages; production deployment and lab validation are outside its
scope. See [Releases and downloads](releases.md) for product IDs, exact inputs,
versioning, package verification and publication steps.

## Agent profiles

Two manually selected profiles live in `.github/agents`:

- **script-maintainer** prepares a bounded code/runbook change and isolated-check evidence.
- **source-reviewer** reads source and reports concrete findings without edit or shell tools.

The profiles use repository instructions and explicitly listed local tools;
neither grants GitHub MCP tools or declares secrets. A profile file configures
behavior; it does not activate a subscription,
enable account access, start a session or authorize spending. Availability and
usage limits depend on GitHub account/repository settings. Selecting and assigning
an agent is a separate action. Agent output receives the same review as any PR.

## Repository controls

`CODEOWNERS` identifies the maintainer; requiring owner review needs a repository
ruleset. Issue forms, the PR template and the security policy provide contribution
entry points. Projects, milestones, Wiki availability, private vulnerability
reporting and agent access are configured in GitHub and must be verified there.
Do not infer that a control is enabled solely because this guide describes it.

## Configuration references

- [GitHub custom agent configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)
