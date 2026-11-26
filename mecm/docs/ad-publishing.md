# Prepare Active Directory publishing

**You do not manually add client computers or individual SMS objects under AD's
System container before discovery.** Client computer accounts stay in their
normal OUs. AD System Discovery reads those OUs independently of site publishing.
For publishing, prepare the schema, `System Management` container and delegation;
Configuration Manager then creates and maintains its site information there.

This procedure covers a standalone primary site publishing in its own domain.
It can be completed before site installation or added to an existing site before
enabling publishing. Publishing is recommended for trusted service location but
is not a prerequisite for basic site operation or AD System Discovery.
See Microsoft's [schema preparation](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/network/extend-the-active-directory-schema)
and [publishing configuration](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/configure/publish-site-data).

## Record the decision and prepare the schema

1. Have the AD owner record the target forest/domain, publishing site-server
   computer account, change approval, replication health and recovery arrangements.
   Schema extension is a forest-wide change; do not run it as an exploratory test.
2. Check whether that forest was already extended for Configuration Manager.
   Have the schema administrator inspect the existing `mS-SMS-*` classes and
   attributes against Microsoft's schema list and retain the prior extension
   evidence if available. Current branch uses the same extensions as earlier
   supported Configuration Manager generations; a new site is not a reason to
   repeat a completed extension.
3. If absent, an authorized Schema Admin signs in to the schema-master domain
   controller and runs `SMSSETUP\BIN\X64\extadsch.exe` from approved ConfigMgr
   installation media against the intended forest.
   Use the directory team's controlled administrative session. Do not grant the
   site-server computer Schema Admin membership.
4. Read `extadsch.log` at the root of the system drive on the execution host.
   Retain its successful extension result and resolve any errors with the AD
   owner. Confirm replication of the added schema objects before continuing.

## Create the container and delegate narrowly

1. On an approved AD administration host, open **ADSI Edit**, connect to the
   **Default naming context** of the target domain and expand the domain root.
2. Expand `CN=System`. If `CN=System Management` exists, use it; do not create
   a duplicate or delete existing site objects. If absent, right-click `CN=System`,
   select **New > Object**, choose class **container**, and enter
   **System Management** as its value. Finish the wizard.
3. In **Active Directory Users and Computers**, enable **View > Advanced
   Features**. Open **System > System Management > Properties > Security**.
   Add the publishing primary site-server's **computer account**; enable the
   **Computers** object type in the picker. Confirm the selected domain and name.
4. In **Advanced**, edit/add its permission entry: **Allow**, **Full control**,
   applying to **This object and all descendant objects**. Check the effective
   permission and record the resulting ACL. Repeat only for other authorized
   primary site servers that publish to this domain.

This same-domain procedure delegates on **System Management**, not on the whole
**System** container. A separate Active Directory Forest Account, especially in
an untrusted forest, has different documented requirements. Do not reuse this
recipe for that topology: have the AD owner review Microsoft's forest-account
permissions, credentials and target scope before enabling it.

## Enable publishing and verify

1. In the ConfigMgr console, open **Administration > Hierarchy Configuration >
   Active Directory Forests**. Review the intended forest's properties; add the
   forest if necessary. Verify its account and **Publishing** configuration.
2. Open **Administration > Site Configuration > Sites**, select the primary
   site, open **Properties > Publishing**, and select the intended forest.
3. On the site server, inspect `hman.log` in the configured site `Logs` directory
   for publication processing and errors. In AD, refresh `System Management` and
   verify the site's generated `SMS-Site-*` and applicable `SMS-MP-*` objects
   contain the intended site/MP information. Allow the agreed replication window.
4. If objects are missing or access is denied, stop and verify the publishing
   selection, schema replication, account identity and descendant ACL. Do not
   create the SMS objects yourself or grant broad domain rights to make it work.

If publishing is deliberately omitted, record the alternative client service
location design. The [manual pilot install](client-onboarding.md) supplies an
initial MP and explicit site code; future MP location/failover still needs the
approved design described in Microsoft's
[service location guidance](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/understand-how-clients-find-site-resources-and-services).

**Retain privately:** publishing decision, approved schema result, target
container/ACL evidence, publication logs and generated-object verification.
An AD object appearing does not prove client installation or patching works.
