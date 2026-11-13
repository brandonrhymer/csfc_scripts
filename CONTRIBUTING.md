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

## Security reports

Use [SECURITY.md](SECURITY.md) for vulnerabilities. Public issues and pull requests
must not contain exploitable operational details, private evidence or credentials.
