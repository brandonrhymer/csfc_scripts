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
[#11](https://github.com/brandonrhymer/csfc_scripts/issues/11).

Keep versioned operator instructions beside scripts. The Wiki can provide
orientation and links to those runbooks; it should not maintain a second copy of
parameters, safety requirements or validation claims.

## Automated checks

The [Offline validation workflow](../.github/workflows/ci.yml) runs on pull
requests, pushes to `main`, and manual dispatch. Its stable job names are:

| Check | Environment | Scope |
| --- | --- | --- |
| Linux offline checks | Ubuntu 24.04, Python 3, Bash and PowerShell 7.4+ | Discovers all `tests/test_*.py` suites; sanitizer regressions including Unix permissions |
| Windows offline checks | Windows Server 2022; Windows PowerShell 5.1 and PowerShell 7.4+ | Parser/Defender helpers, MECM mocks, sanitizer regressions |
| KRBTGT offline release gates | Windows Server 2022; Windows PowerShell 5.1 | Committed hashes, parser, analyzer and mocked Pester suite |

The tests use synthetic inputs and do not contact operational targets. Hosted
runner setup is network-connected: checkout retrieves source and the KRBTGT job
installs missing Pester 3.4.0 and PSScriptAnalyzer 1.25.0 development dependencies
from PowerShell Gallery. This does not change the offline runtime packages.
The workflow uses a read-only contents token, disables checkout credential
persistence and pins its action to a full commit SHA. Dependabot proposes weekly
GitHub Actions dependency updates; review those PRs before merging.

The [validation matrix](validation.md#package-check-matrix) lists local commands
and evidence limits. Require the named checks in repository rules only after
their first observed successful run. Neither committed workflow files nor a
passing mock prove that platform/lab validation is complete.

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
