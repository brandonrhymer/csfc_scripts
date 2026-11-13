@{
    RootModule        = 'KrbtgtRotation.psm1'
    ModuleVersion     = '0.1.1'
    GUID              = 'bb4eebbd-d8bd-4537-9c67-4c1ae6ad43cb'
    Author            = 'csfc-scripts contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'Fail-closed, two-DC KRBTGT routine-rotation workflow for the approved Windows Server 2022 profile.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Install-KrbtgtRotationLocalSetup',
        'Invoke-KrbtgtPreflight',
        'Invoke-KrbtgtTest',
        'Invoke-KrbtgtReset'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'KRBTGT', 'WindowsServer2022')
            ProjectUri = 'https://github.com/brandonrhymer/csfc_scripts/tree/main/windows/reset-krbtgt'
        }
    }
}
