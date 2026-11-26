# Import, approve and run a client maintenance script

Use this shared console walkthrough with the selected product's runbook and
[pilot checklist](pilot-checklist.md). These scripts are development candidates;
synthetic CI does not establish real-client acceptance. Begin on one approved
lab client. No source edits or interactive input on the client are required.

## Assign permissions and verify the artifact

The author, approver and runner below are responsibilities and custom role
patterns, not three automatically created ConfigMgr security roles. The site
administrator configures **Administration > Security > Security Roles** and
**Administrative Users**, assigning the necessary collection access and security
scope. Keep the target collection limited to the approved pilot.

| Permission | Runner | Author | Approver |
| --- | --- | --- | --- |
| Collection: Run Script | Yes | No | No |
| Site: Read | Yes | Yes | Yes |
| SMS Scripts: Read | Yes | Yes | Yes |
| SMS Scripts: Create / Delete | No | Yes | No |
| SMS Scripts: Modify | No | Yes | Yes |
| SMS Scripts: Approve | No | No | Yes |

This is Microsoft's [Run Scripts permission model](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-deploy-scripts).
Verify the assigned scope as well as permission names. Keep script-author
self-approval disabled in **Hierarchy Settings > General**; an independent
approver reviews the actual code and parameter definitions.

1. Verify the selected downloaded product version, release/candidate identity
   and SHA-256 manifest through the approved acquisition process. Extract it with
   paths intact; read its own runbook, parameters, effects and recovery limits.
2. Verify the target has a supported, healthy ConfigMgr client, PowerShell 5.1,
   access to site communications and the required local prerequisites. These
   scripts run as **SYSTEM/the computer account**, not the console operator.
   A resource accessible to your user account might not be accessible to SYSTEM.
3. For application-specific products, complete [policy approval](policies.md)
   and stage the independently approved policy/hash and required files locally
   through the approved delivery process. Do not put policies or secrets in
   script source. The script does not download or create an approval policy.

## Create the script and inspect its parameters

1. Open **Software Library > Scripts > Create Script**. Give it a name that
   identifies product/version and purpose; choose PowerShell and **Import** the
   exact extracted `Invoke-Mecm*.ps1` entrypoint. Review the imported code.
2. On the wizard's **Script Parameters** page, inspect every parameter, type,
   default and validation rule. Run Scripts supports strings, integers and
   predefined value lists, with at most ten parameters. Not every restriction
   implemented inside a script is necessarily imported into the console UI.
3. Confirm this repository's current parameter contract against the product
   runbook. Configure/verify console validation without changing the script's
   approved source:

| Product scope | Parameter definitions |
| --- | --- |
| All eleven | `Mode`: String, `Preview` / `Apply`, default `Preview`; `TimeoutSeconds`: Integer, 5–120, default 60 |
| Cache cleanup | `RetentionDays`: Integer, 1–3650, default 30 |
| CcmEval | `EnableDisabled`: String, `No` / `Yes`, default `No`; `OverdueHours`: Integer, 1–8760, default 72 |
| DNS registration | `RegistrationOwnership`: String, `Unknown` / `Client` / `Dhcp` / `Other`, default `Unknown`; `AllAdaptersApproved`: String, `No` / `Yes`, default `No` |
| Service start, agent restart, task enablement, staging cleanup, configuration restore | `PolicyPath` and `PolicySha256`: Strings; supply approved local path and independently approved 64-character SHA-256 digest; empty defaults do not authorize Apply |
| Computer policy refresh, DNS cache flush, time sync | No additional parameters |

4. Finish creation and have the independent approver select the script in
   **Software Library > Scripts > Approve/Deny**. The approver checks the exact
   imported content/version, allowed targets, default Preview behavior and
   parameter definitions. Retain the approval record privately.
5. Verify **Approval State = Approved**. Editing or copying a script requires
   renewed approval; do not treat an older approval as covering revised code.
   Never edit a script while it is executing on clients; reconcile active runs
   before creating/reapproving a revision.

## Run Preview and reconcile every target

1. In **Assets and Compliance > Device Collections**, select the approved pilot
   collection, update membership if needed, and inspect **Show Members**.
   Confirm every expected device and count; exclude other clients before running.
   This walkthrough uses **immediate execution**: submit it during the approved
   change window, selecting **Run script immediately** if a Scheduling page is
   present. Do not assume a collection maintenance window delays Run Scripts.
2. Choose **Run Script**, select the approved product/version, and inspect every
   parameter. Explicitly set **Mode = Preview** and the approved policy or other
   inputs. Enter console values **without enclosing quotation marks**, even a
   path containing spaces. Values cannot contain single quotes/apostrophes; do
   not paste a PowerShell command line into a parameter field. Use an approved
   compatible staging path if necessary.
3. Review the summary's script, collection and values before submitting. Record
   the execution ID, target count and timestamp. A button click is not success.
4. Open **Monitoring > Script Status**, select that execution and inspect its
   per-device details/results. Compare responding clients with the expected
   target list: unknown/offline clients may be absent from charts. Output is
   limited to 4 KB, so keep the compact result and any required client logs.
5. Read **status, reason and counters**, not only invocation success/exit code.
   `Changed`, `Already correct`, `Skipped` and `Failed` describe the script's
   reported outcome. In Preview, verify the proposed scope matches approval.
   A safe skip is not proof that the intended remediation occurred.

## Apply only after reviewing Preview

1. Reconcile Preview with the approved pilot criteria and obtain the product's
   required change approval. Recheck collection membership and the exact policy
   hash; scope can change between runs.
2. Run the same approved script again with **Mode = Apply** and the reviewed
   parameters. This is a separate explicit execution. Never widen a failed
   pilot to an operational collection to gather more evidence.
3. Inspect all per-device results and perform the product-specific post-checks.
   A request accepted by CcmEval, DNS or time services does not by itself prove
   the downstream result. Record changes, unchanged devices, skips and failures.
4. For timeout, partial failure, unknown or missing results, inspect the target
   state and logs before any retry. The requested effect may already have happened.
   Do not rerun an entire collection blindly; reconcile each uncertain device.

Start diagnosis on the client with `%windir%\CCM\Logs\Scripts.log` and
`CcmMessaging.log`. For delivery/result-routing failures, have the site owner
inspect `MP_RelayMsgMgr.log` on the MP and `SMS_Message_Processing_Engine.log` on
the site server. Retain execution ID and timestamps to correlate the same run.

Microsoft describes a **one-hour Run Scripts execution-system window**; a client
offline for that entire period needs a later run. This is not a configurable
per-script runtime timeout. Each product's `TimeoutSeconds` bounds its own
implementation as documented, with applicable wrapper overhead. Neither value
guarantees cancellation of an external action or proves that an unreported
mutation did not occur.

Keep script deployment separate from servicing ConfigMgr itself. Do not use
these application-agent operations to restart the ConfigMgr client or its
Run Scripts execution host. Follow the exact exclusions in the product runbook.

**Evidence:** approved artifact/script identity, role/scoping review, target
membership, parameter values, independent approval, Preview/Apply execution IDs,
per-device results and product-specific follow-up. Keep all operational evidence
private. Source: [Microsoft create and run scripts](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-deploy-scripts).
