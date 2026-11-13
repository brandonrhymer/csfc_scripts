# Application policy approval

Service start, agent restart, task enablement, staging cleanup and configuration
restore require a local JSON policy and its independently approved SHA-256 hash.
Their `*.policy.example.json` files are synthetic schema examples. Shipping an
example in a ZIP does not approve its targets or make it active.

## Prepare an approved policy

1. Have the application owner identify the exact local service, task or file
   scope, the intended change, its dependencies, and recovery procedure. Follow
   the product runbook for required fields and supported restrictions.
2. Copy the matching example into your private change record and replace its
   synthetic values. Review the complete policy and any referenced configuration.
   Do not put credentials, customer identifiers, machine-specific values or
   actual environment policies in this repository or public issue attachments.
3. Obtain independent approval of that exact content. Compute its hash with
   `Get-FileHash -LiteralPath <approved-policy-path> -Algorithm SHA256` and record
   the digest with the approval. A digest proves byte identity; it does not prove
   that a policy is safe or approved. Do not automatically trust whatever hash
   happens to be present on a target computer.
4. Stage the policy and required local files through the approved software
   delivery process. Restrict write access to authorized administrators and
   SYSTEM. Keep untrusted users and the application itself from changing policy
   files or approved source configurations.
5. Supply `PolicyPath` and `PolicySha256` as MECM parameters, with `Mode=Preview`.
   Compare the output with the approved scope. Import and approval use the
   normal MECM author, approver and runner roles; no script source edit is needed.
6. Apply only after the required pilot and change approval. If policy content,
   service identity, task definition or approved file content changes, review
   it again and pin the new approved hash. Never relax a rejection just to make
   an unfamiliar client pass.

Read each product runbook for the exact schema. These deliberately narrow
contracts can reject otherwise legitimate applications. Supporting a broader
schema or target class is a separate reviewed code change, not an operator
override. Keep pilot records and actual policies in an approved private location.

## Current validation boundary

GitHub Actions exercises synthetic policies and isolated providers/filesystem
fixtures. No real application targets have been approved, and no MECM environment
is available for pilot validation. CI packages are development candidates.
The [pilot checklist](pilot-checklist.md) tracks the operational evidence still
needed before deployment.
