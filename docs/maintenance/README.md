# Maintenance readiness and validation decisions

These guides cover the product preparation work possible without an operational
environment. They are not cleanup authorization or completed pilot evidence.
GitHub Actions remains the primary integration/test gate; actual site behavior
requires the separate acceptance evidence in each guide.

| Product area | Preparation available | Next required input |
|---|---|---|
| [Distribution-point cleanup](distribution-point.md) | Native tool scope, one-target assessment/approval sequence and recovery requirements | Owner-approved target/version/health inventory and any demonstrated gap in native coverage |
| [WSUS/SUP maintenance](wsus-sup.md) | Native coverage, private inventory worksheet, ownership and recovery boundaries | Actual topology/settings/results and evidence of an unmet requirement |
| [KRBTGT historical Test failure](krbtgt-evidence.md) | Current-source explanation, private evidence worksheet and isolated receipt-policy regressions | Historically executed revision, original failure stage and setup/reconciliation evidence |
| [Integration lab](../validation-lab.md) | Unprovisioned topology, media/resource decisions and acceptance matrix | Approved owner, resources, entitlements, build versions, isolation and recovery plan |

Microsoft already supplies substantial DP and SUP maintenance functionality.
No additional cleanup script is selected until an actual unmet need is
demonstrated. Likewise, a current passing KRBTGT guard test does not establish
the historical incident's cause or justify changing the reset safeguards.

Keep completed worksheets, actual identities, topology, credentials and raw
reports in approved private storage. Public examples and test fixtures remain
synthetic. Do not run an operational command merely to fill an evidence gap.

The [eleven client-maintenance candidates](../../mecm/client-maintenance/README.md)
retain their [outstanding pilot checklist](../../mecm/client-maintenance/pilot-checklist.md).
Milestone 2 and the applicable Milestone 3 issues remain open for that evidence.
Source integration, release publication and operational rollout are separate
decisions; these guides record preparation, not deployment readiness.
