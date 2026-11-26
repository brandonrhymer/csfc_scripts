# Prepare SQL and installation accounts

Complete this with the SQL and platform owners before [site Setup](02-install.md).
Use the approved build worksheet, not guessed account names or instance paths.
Sources reviewed 2026-11-25: Microsoft's
[site installation permissions](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/deploy/install/prerequisites-for-installing-sites),
[SQL configuration](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/supported-configurations-for-sql-server)
and [SQL version/compatibility matrix](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/configs/support-for-sql-server-versions).

## Approve identities and rights

| Identity | Target and required rights | Lifecycle |
| --- | --- | --- |
| Human setup operator | Local Administrator on site server, SQL site-database hosts and SMS Provider hosts; SQL instance `sysadmin` | Approve for installation/recovery; remove temporary human grants only after the owner verifies ongoing responsibilities |
| Site-server computer account | SQL instance `sysadmin`; local Administrator on applicable site-system hosts when used for site-system installation/management | Retain these ongoing rights; SQL `sysadmin` is not a setup-only grant |
| Site-system installation identity | Local Administrator and **Access this computer from the network** on each target site-system host | Default can be the site-server computer; retain an approved alternate account's rights for role installation, reconfiguration and maintenance |
| AD schema operator | Schema Admin for the authorized forest extension | Separate controlled AD change; never grant this to the site-server computer |
| Discovery/publishing identities | Read the approved discovery OUs; publishing delegation as documented separately | Different tasks and scopes; see [AD publishing](ad-publishing.md) and [discovery](client-onboarding.md) |

Record each actual identity, target, grant owner and review date privately.
For a remote MP/DP installed by Setup, verify the installation identity's rights
before selecting the role. If those rights are unavailable, omit that remote
role during Setup and add it later with an approved account; do not proceed on
the assumption that local site-server Administrator rights cover every host.
Never place account passwords in scripts, command examples or this worksheet.
Microsoft distinguishes these ongoing [account responsibilities](https://learn.microsoft.com/en-us/intune/configmgr/core/plan-design/hierarchy/accounts).

## Configure and inspect the SQL instance

1. Select a supported SQL **edition, version and CU** for the intended ConfigMgr
   release. A standalone primary requires the supported full SQL edition, not
   a secondary site's SQL Express option. Record licensing and servicing ownership.
2. Install the Database Engine in a dedicated supported instance. Record whether
   it is local/remote and default/named. A default instance is addressed by server
   FQDN; a named instance uses the actual instance name. Do not derive either
   from its disk folder.
3. Use Windows authentication. The standard instance and site-database collation
   is `SQL_Latin1_General_CP1_CI_AS`; Microsoft's documented China GB18030
   exception requires a deliberate design decision. Do not change collation on
   a populated shared server to follow this guide.
4. In **SQL Server Configuration Manager > SQL Server Network Configuration >
   Protocols for the instance**, enable TCP/IP and set the approved static TCP
   port. Disable dynamic-port allocation for that instance as documented. Restart
   the SQL service within the change window when required; verify the listening
   port and allow only the necessary network flows. Record SQL and Service Broker
   ports separately; do not assume every named instance uses 1433.
5. In SQL Server Management Studio, connect using Windows authentication to the
   exact instance. Configure approved minimum/maximum server memory, reserving
   memory for Windows and colocated roles. Size and locate database data, log and
   tempdb files with the DBA; record free space, growth settings and monitoring.
   There is no universal safe memory or disk value for this unspecified site.
6. Select the site-database compatibility level from Microsoft's matrix for both
   SQL and ConfigMgr versions. For example, SQL 2022 compatibility **160** support
   starts with ConfigMgr **2603**; an older ConfigMgr build must not inherit that
   choice without checking support. Let Setup create its database; do not create
   a speculative empty database with guessed settings.
7. Verify setup and computer-account permissions with the DBA, and ensure Remote
   Registry is enabled on the SQL host during site installation. Complete the
   site prerequisite check before starting installation.

## Read-only evidence queries

Run in an SSMS query window connected to the recorded instance. The last query
checks the database after Setup; replace `CM_LAB` with the actual database name.

```sql
SELECT SERVERPROPERTY('ServerName') AS ServerName,
       SERVERPROPERTY('InstanceName') AS InstanceName,
       SERVERPROPERTY('ProductVersion') AS ProductVersion,
       SERVERPROPERTY('Edition') AS Edition,
       SERVERPROPERTY('Collation') AS Collation,
       SERVERPROPERTY('IsIntegratedSecurityOnly') AS WindowsAuthenticationOnly;
SELECT name, value_in_use
FROM sys.configurations
WHERE name IN ('min server memory (MB)', 'max server memory (MB)');
SELECT name, collation_name, compatibility_level, state_desc
FROM sys.databases WHERE name = N'CM_LAB';
SELECT DB_NAME(database_id) AS DatabaseName, type_desc, physical_name,
       size, growth, is_percent_growth
FROM sys.master_files WHERE database_id = DB_ID(N'CM_LAB');
```

Pass only when the instance/build/edition, collation, authentication, memory,
paths and post-setup compatibility/state match the approved worksheet. A null
InstanceName means a default instance. An empty site-database result before
Setup is expected; afterwards it is a stop point. Permissions can limit metadata
visibility, so have the DBA interpret missing rows rather than changing grants
blindly. Retain the private query output, actual listener checks and prerequisite
result. Do not publish operational configuration in GitHub.
