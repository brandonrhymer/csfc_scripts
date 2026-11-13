# Contributing

Start with an issue that states the operator problem, the affected package and
observable acceptance criteria. Keep a change small enough to review with its
runbook. Use the [GitHub workflow guide](docs/github-workflow.md) for issue,
milestone, project and agent conventions.

## Source and operator contract

- Match the package's documented language, shell and execution platform.
- Prefer explicit runtime inputs and focused scripts. Avoid requiring operators
  to edit source or install an additional framework for a routine task.
- Describe prerequisites, preview behavior, changes, output, failure and recovery
  in the script's own README. Keep the shared indexes current.
- Preserve confirmation and fail-closed behavior. A timeout can leave an external
  action unresolved; do not add automatic retries for mutations without a safe,
  documented reconciliation design.
- Keep operational material outside Git. All fixtures, example hosts and accounts
  must be synthetic. Inspect the staged diff rather than staging a working
  directory that contains private inputs or output.

## Validation and review

Use the [validation matrix](docs/validation.md#package-check-matrix) to select
existing isolated checks. Run MECM test files in separate PowerShell processes
because they substitute command names. A check must fail when its expected
behavior is violated; do not weaken assertions to obtain a green result.

Describe the tested commit, platform, command and outcome in the pull request.
State which checks remain unrun. CI does not contact operational targets and
does not establish lab readiness or authorization to deploy.

Changes inside `windows/reset-krbtgt` also follow its
[contribution instructions](windows/reset-krbtgt/CONTRIBUTING.md).
Review intentional package changes before updating its manifest/hashes, and run
its complete release gate against the resulting package. Keep an unexplained
hash mismatch visible as a failure.

Use a pull request with the applicable issue linked. Maintainer review and
applicable checks precede merge; actual enforcement is configured separately in
repository rulesets. Do not claim an unobserved check or deployment succeeded.

## Product versions and packaging

The [product catalog](tools/release/catalog.json) defines each operational
script's product ID, version, entry point, runbook and required files. Treat the
downloaded ZIP as an operator interface: it must contain everything required by
the selected entry point and its operator instructions. Keep repository-relative
paths intact so imports and included instructions work after extraction. Shared
indexes may link to other products; make the selected product's starting point
clear in its runbook.

Package contents come from the catalog's explicit entry point, runbook,
dependency and shared-file lists, plus any preserved package manifest. Markdown
links do not silently pull other products into a package. Add required offline
instructions and dependencies explicitly. The repository's `.gitattributes`
keeps tracked text at LF line endings so hosted checks exercise the line endings
shipped from Git.

When a product's payload changes, increase its catalog version in the same
change. CI runs `bun tools/release/versions.ts` to require a strictly newer
version for changed payloads and reject downgrades. Use semantic versions and
do not replace an already released version with different contents. Shared
packaged documents and dependencies can affect several products; review each
affected catalog entry. All four KRBTGT products carry the complete KRBTGT
publication manifest, so a change within it affects all four.

Changes to `tools/release/package.ts` or `tools/release/zip.ts` require strictly
newer versions for every existing product because the packaging engine or
templates can change every ZIP's bytes. Ordinary script, dependency and runbook
changes require version increases only for the affected products.

Versions remain independent: unrelated products do not need a version bump, and
a product change does not require a bundle release. A product ZIP remains stable
across unrelated commits because its embedded identity uses the product tag and
payload digest. The accompanying release manifest and provenance retain the
exact build commit.

Every new operational script needs a catalog entry, its complete dependency list,
a version and a runbook. Add or update appropriate isolated checks. A proposed
script is not a product until its implementation and operator instructions exist;
the pending MECM remediation batch is not included merely because it is planned.

The **Product package checks** job builds all candidate products and a bundle
from committed source, then verifies packaging and extraction. Bun 1.4.2 is a
development dependency only. Use the [local packaging commands](docs/releases.md#local-packaging)
to inspect a package before review. Review the catalog and extracted contents as
well as the source diff; a successful ZIP build alone does not establish correct
runtime behavior.

After merge, use **Prepare product release** to prepare a draft for one product
or a selected bundle. Publication is a separate maintainer action. The quarterly
bundle schedule does not publish a release on each script change. See the
[release guide](docs/releases.md#prepare-a-release) for inputs and review steps.

## Security reports

Use [SECURITY.md](SECURITY.md) for vulnerabilities. Public issues and pull requests
must not contain exploitable operational details, private evidence or credentials.
