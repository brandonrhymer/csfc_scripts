# Splunk Universal Forwarder

Use Windows PowerShell 5.1 elevated. Preview with `-WhatIf`.

Splunk installation takes `-MsiPath`, `-ReceivingIndexer`, `-DeploymentServer`,
and `-AcceptLicense`. Review the license and approve the package before use.
For endpoint syntax only, reserved examples are `indexer.example.invalid:9997`
and `deployment.example.invalid:8089`. Installation runs once on the local
computer; the supplied source's unused computer loop did not perform remoting.

[Uninstallation](uninstall-forwarder.ps1) stops forwarding and invokes the
MSI uninstaller for matching registered products. Plan forwarding continuity
before use. Both scripts treat MSI exit 3010 as completed with reboot required;
neither reboots automatically. Verify service and application state afterward.

See [validation and remaining limitations](../../docs/attachment-validation.md).
