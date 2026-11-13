#requires -Version 5.1
<#
.SYNOPSIS
Restores one approved nonsecret display configuration. Preview is the default.
.DESCRIPTION
Standalone offline Windows PowerShell 5.1. Requires a reviewed local JSON policy
and its independently approved SHA256. See config-restore.md before use.
.PARAMETER Mode
Preview or Apply; no prompts. Preview performs no content writes or deletions.
.PARAMETER PolicyPath
Exact local JSON policy path. No bundled policy is selected automatically.
.PARAMETER PolicySha256
SHA256 of the reviewed policy bytes, obtained through the approval process.
.PARAMETER TimeoutSeconds
Owned worker deadline, 5-120 seconds. Timeout does not undo external I/O.
#>
[CmdletBinding()]
param([string]$Mode = 'Preview', [string]$PolicyPath = '', [string]$PolicySha256 = '', [int]$TimeoutSeconds = 60)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$product = 'mecm-config-restore'
if ($Mode -notin @('Preview','Apply') -or $TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 120 -or
    $PolicySha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($PolicyPath)) {
    @{ Product=$product; Status='Failed'; Reason='InvalidParameter'; MayHaveChanged=$false; OutcomeUncertain=$false } | ConvertTo-Json -Compress
    exit 2
}
$Mode = if ($Mode -ieq 'Apply') { 'Apply' } else { 'Preview' }
$worker = {
    param([Parameter(Mandatory=$true)]$settings)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Set-StrictMode -Version 2.0
    if ($settings -isnot [pscustomobject] -or $settings.Mode -isnot [string] -or $settings.Mode -cnotin @('Preview','Apply') -or
        $settings.PolicyPath -isnot [string] -or $settings.PolicySha256 -isnot [string] -or $settings.PolicySha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'InvalidWorkerSettings' }
    $Mode = [string]$settings.Mode
    $result = [ordered]@{ Product='mecm-config-restore'; Mode=$Mode; Status='Failed'; Reason='InspectionFailed';
        PlannedBytes=[long]0; WrittenBytes=[long]0; BackupState='NotCreated'; DestinationState='NotInspected';
        MayHaveChanged=$false; OutcomeUncertain=$false }
    $stage = 'PolicyValidation'
    $held = New-Object 'Collections.Generic.List[IDisposable]'
    try {
        # Native handles keep every ancestor from being renamed while in use.
        # OPEN_REPARSE_POINT plus final-path equality rejects junctions, symlinks,
        # short-name/substituted-drive aliases. File operations require one link.
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MaintenanceFiles {
 [StructLayout(LayoutKind.Sequential, Pack=4)] public struct Info {
  public uint Attributes; public long Created; public long Accessed; public long Written;
  public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
 }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder p,uint n,uint f);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int c,ref int i,uint n);
 public static Info Inspect(SafeFileHandle h) { Info i; if(!GetFileInformationByHandle(h,out i)) throw new IOException("HandleInspectionFailed"); return i; }
 public static string Canonical(string p) {
  if(String.IsNullOrEmpty(p) || p.Length>220 || !System.Text.RegularExpressions.Regex.IsMatch(p,@"^[A-Za-z]:\\[^\\]") || p.IndexOfAny(new char[]{'/','*','?','[',']','\0'})>=0 || p.Substring(2).Contains(":")) throw new IOException("InvalidLocalPath");
  string[] parts=p.Substring(3).Split('\\');
  foreach(string part in parts) if(part.Length==0 || part=="." || part==".." || part.EndsWith(".") || part.EndsWith(" ") || System.Text.RegularExpressions.Regex.IsMatch(part,@"^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])($|\.)",System.Text.RegularExpressions.RegexOptions.IgnoreCase)) throw new IOException("PathAliasRejected");
  string full=Path.GetFullPath(p); if(!String.Equals(full,p,StringComparison.OrdinalIgnoreCase)) throw new IOException("PathNotCanonical");
  var drive=new DriveInfo(Path.GetPathRoot(p)); if(drive.DriveType!=DriveType.Fixed || drive.DriveFormat!="NTFS") throw new IOException("FixedNtfsRequired");
  return full;
 }
 public static void Scope(string p) {
  Canonical(p); if(p.Substring(3).Split('\\').Length<3) throw new IOException("ScopeTooBroad");
  string lower=p.ToLowerInvariant();
  foreach(Environment.SpecialFolder folder in new Environment.SpecialFolder[]{Environment.SpecialFolder.Windows,Environment.SpecialFolder.ProgramFiles,Environment.SpecialFolder.ProgramFilesX86}) {
   string protectedRoot=Environment.GetFolderPath(folder).TrimEnd('\\');
   if(protectedRoot.Length>0 && (String.Equals(p,protectedRoot,StringComparison.OrdinalIgnoreCase) || p.StartsWith(protectedRoot+"\\",StringComparison.OrdinalIgnoreCase))) throw new IOException("CriticalScopeRejected");
  }
  foreach(string segment in p.Substring(3).Split('\\')) if(System.Text.RegularExpressions.Regex.IsMatch(segment,@"^(windows|system32|syswow64|program files( \(x86\))?|ccm|ccmcache|ccmsetup|sms_ccm|sccmcontentlib|logs?|evidence|packages?|recovery|system volume information|\$recycle.bin)$",System.Text.RegularExpressions.RegexOptions.IgnoreCase)) throw new IOException("CriticalScopeRejected");
  if(lower.Contains("\\programdata\\microsoft")) throw new IOException("CriticalScopeRejected");
 }
 static void Check(SafeFileHandle h,string p,bool directory) {
  Info i=Inspect(h); if((i.Attributes&0x400)!=0 || (((i.Attributes&0x10)!=0)!=directory) || (!directory && i.Links!=1)) throw new IOException("UnsafeFileIdentity");
  var b=new StringBuilder(1024); uint n=GetFinalPathNameByHandleW(h,b,1024,0); if(n==0 || n>=1024 || !String.Equals(b.ToString(),@"\\?\"+p,StringComparison.OrdinalIgnoreCase)) throw new IOException("FinalPathMismatch");
 }
 public static SafeFileHandle DirectoryLock(string p) {
  var h=CreateFileW(p,0,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
  if(h.IsInvalid) { h.Dispose(); throw new IOException("DirectoryLockFailed"); }
  try { Check(h,p,true); return h; } catch { h.Dispose(); throw; }
 }
 public static FileStream Open(string p,bool write,bool delete) {
  Canonical(p); var h=CreateFileW(p,0x80000000u|(write?0x40000000u:0u)|(delete?0x10000u:0u),0,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
  if(h.IsInvalid) { h.Dispose(); throw new IOException("ExclusiveOpenFailed"); }
  try { Check(h,p,false); var i=Inspect(h); if((i.Attributes&~(uint)(0x20|0x80|0x2000))!=0) throw new IOException("UnsupportedFileAttributes"); return new FileStream(h,write?FileAccess.ReadWrite:FileAccess.Read); } catch { h.Dispose(); throw; }
 }
 public static FileStream NewBackup(string p) {
  Canonical(p); var h=CreateFileW(p,0xC0040000,0,IntPtr.Zero,1,0x00200000,IntPtr.Zero);
  if(h.IsInvalid) { h.Dispose(); throw new IOException("BackupCreateFailed"); }
  try { Check(h,p,false); return new FileStream(h,FileAccess.ReadWrite); } catch { h.Dispose(); throw; }
 }
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileTime(SafeFileHandle h,ref long c,ref long a,ref long w);
 public static void CopyTimes(FileStream source,FileStream destination) { Info i=Inspect(source.SafeFileHandle); if(!SetFileTime(destination.SafeFileHandle,ref i.Created,ref i.Accessed,ref i.Written)) throw new IOException("BackupMetadataFailed"); }
 public static void Delete(FileStream f) { int yes=1; if(!SetFileInformationByHandle(f.SafeFileHandle,4,ref yes,4)) throw new IOException("HandleDeletionFailed"); }
 public static byte[] Read(FileStream f,int max) { if(f.Length>max) throw new IOException("FileTooLarge"); f.Position=0; byte[] bytes=new byte[(int)f.Length]; int at=0; while(at<bytes.Length) { int n=f.Read(bytes,at,bytes.Length-at); if(n==0) throw new IOException("ShortRead"); at+=n; } return bytes; }
 public static string Hash(byte[] b) { using(var s=System.Security.Cryptography.SHA256.Create()) { return BitConverter.ToString(s.ComputeHash(b)).Replace("-",""); } }
}
'@
        $lockedDirectories = @{}
        function Lock-Parents([string]$Path, [bool]$IsDirectory = $false) {
            $null = [MaintenanceFiles]::Canonical($Path)
            $parent = if ($IsDirectory) { $Path } else { [IO.Path]::GetDirectoryName($Path) }
            $parts = $parent.Substring(3).Split('\')
            $current = $parent.Substring(0,3)
            # Lock the volume root as well; aliases are checked on every handle.
            if (-not $lockedDirectories.ContainsKey($current)) {
                $held.Add([MaintenanceFiles]::DirectoryLock($current)); $lockedDirectories[$current]=$true
            }
            foreach ($part in $parts) {
                $current = [IO.Path]::Combine($current,$part)
                if (-not $lockedDirectories.ContainsKey($current)) {
                    $held.Add([MaintenanceFiles]::DirectoryLock($current)); $lockedDirectories[$current]=$true
                }
            }
        }
        function Read-StrictJson([byte[]]$Bytes, [string[]]$Fields) {
            $text = (New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes).TrimStart([char]0xFEFF)
            $object = $text | ConvertFrom-Json
            if ($object -isnot [pscustomobject] -or @($object.PSObject.Properties).Count -ne $Fields.Count -or
                @(Compare-Object @($object.PSObject.Properties.Name) $Fields -CaseSensitive).Count -ne 0) { throw 'InvalidSchema' }
            # Flat policy/schema only. Escaped, repeated or differently cased keys
            # are rejected rather than accepted with JSON last-key-wins behavior.
            $keys = [regex]::Matches($text,'"([A-Za-z][A-Za-z0-9]*)"\s*:')
            if ($keys.Count -ne $Fields.Count) { throw 'InvalidKeys' }
            foreach ($field in $Fields) { if (@($keys | Where-Object { $_.Groups[1].Value -ceq $field }).Count -ne 1) { throw 'RepeatedKey' } }
            return $object
        }
        function Assert-Integer($Value,[int]$Min,[int]$Max) {
            if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Min -or $Value -gt $Max) { throw 'InvalidPolicyInteger' }
        }
        function Assert-String($Value,[string]$Pattern) {
            if ($Value -isnot [string] -or $Value -cnotmatch $Pattern) { throw 'InvalidPolicyString' }
        }
        function Assert-StringList($Value,[string]$Pattern,[int]$Max=16) {
            if ($Value -isnot [array] -or $Value.Count -lt 1 -or $Value.Count -gt $Max) { throw 'InvalidPolicyList' }
            $seen=@{}
            foreach ($item in $Value) { Assert-String $item $Pattern; if($seen.ContainsKey($item)) { throw 'DuplicatePolicyEntry' }; $seen[$item]=$true }
        }
        function Get-Policy([string[]]$Fields) {
            Lock-Parents ([string]$settings.PolicyPath)
            $stream=[MaintenanceFiles]::Open([string]$settings.PolicyPath,$false,$false); $held.Add($stream)
            $bytes=[MaintenanceFiles]::Read($stream,16384)
            if ([MaintenanceFiles]::Hash($bytes) -ine [string]$settings.PolicySha256) { throw 'PolicyHashMismatch' }
            $policy=Read-StrictJson $bytes $Fields
            if ($policy.SchemaVersion -isnot [int] -or $policy.SchemaVersion -ne 1 -or $policy.Approved -isnot [bool] -or -not $policy.Approved) { throw 'PolicyNotApproved' }
            Assert-String $policy.ApplicationId '^[A-Za-z][A-Za-z0-9-]{2,39}$'
            Assert-String $policy.ApprovalReference '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$'
            if ($policy.ActivityProtocol -isnot [string] -or $policy.ActivityProtocol -cne 'ExclusiveMaintenanceGuard/v1') { throw 'UnsupportedActivityProtocol' }
            return $policy
        }
        # PRODUCT OPERATION START
        $policy=Get-Policy @('SchemaVersion','Approved','ApprovalReference','ApplicationId','ApplicationRoot','ActivityProtocol','SourcePath','SourceSha256','DestinationPath','DestinationBeforeSha256','BackupPath','ConfigurationSchema')
        foreach ($field in @('ApplicationRoot','SourcePath','DestinationPath','BackupPath')) { Assert-String $policy.$field '^[A-Za-z]:\\'; [MaintenanceFiles]::Scope($policy.$field) }
        if ([IO.Path]::GetFileName($policy.ApplicationRoot) -cne $policy.ApplicationId -or
            $policy.DestinationPath -cne (Join-Path $policy.ApplicationRoot 'maintenance-display.json') -or
            $policy.SourcePath -cne (Join-Path $policy.ApplicationRoot 'ApprovedConfiguration\maintenance-display.json') -or
            $policy.BackupPath -cne (Join-Path $policy.ApplicationRoot 'ConfigurationBackup\maintenance-display.before.json') -or
            ($policy.ConfigurationSchema -isnot [string] -or $policy.ConfigurationSchema -cne 'MaintenanceDisplay/v1')) { throw 'ConfigurationScopeMismatch' }
        Assert-String $policy.SourceSha256 '^[A-Fa-f0-9]{64}$'
        Assert-String $policy.DestinationBeforeSha256 '^[A-Fa-f0-9]{64}$'
        if ($settings.PolicyPath -ieq $policy.SourcePath -or $settings.PolicyPath -ieq $policy.DestinationPath -or
            $settings.PolicyPath -ieq $policy.BackupPath) { throw 'OverlappingPolicyPath' }
        foreach ($path in @($policy.SourcePath,$policy.DestinationPath,$policy.BackupPath)) { Lock-Parents $path }
        $guard=[MaintenanceFiles]::Open((Join-Path $policy.ApplicationRoot 'maintenance.guard'),$false,$false); $held.Add($guard)
        if (Test-Path -LiteralPath (Join-Path $policy.ApplicationRoot 'application.active')) { throw 'ApplicationActive' }
        function Assert-Configuration([byte[]]$Bytes) {
            $config=Read-StrictJson $Bytes @('Schema','RefreshSeconds','DisplayLevel')
            if ($config.Schema -isnot [string] -or $config.Schema -cne 'MaintenanceDisplay/v1' -or $config.DisplayLevel -isnot [string] -or $config.DisplayLevel -cnotin @('Normal','Compact')) { throw 'UnsupportedConfiguration' }
            Assert-Integer $config.RefreshSeconds 30 3600
        }
        $stage='SourceValidation'
        $source=[MaintenanceFiles]::Open($policy.SourcePath,$false,$false); $held.Add($source)
        $approved=[MaintenanceFiles]::Read($source,4096)
        if ([MaintenanceFiles]::Hash($approved) -ine $policy.SourceSha256) { throw 'SourceHashMismatch' }
        Assert-Configuration $approved
        $stage='DestinationValidation'
        $destination=[MaintenanceFiles]::Open($policy.DestinationPath,($Mode -eq 'Apply'),$false); $held.Add($destination)
        $before=[MaintenanceFiles]::Read($destination,4096)
        $beforeHash=[MaintenanceFiles]::Hash($before)
        Assert-Configuration $before
        $result.DestinationState='OriginalVerified'
        if ($beforeHash -ieq $policy.SourceSha256) {
            $result.Status='Already correct'; $result.Reason='ApprovedConfigurationPresent'; $result.DestinationState='ApprovedVerified'
        } else {
            if ($beforeHash -ine $policy.DestinationBeforeSha256) { throw 'DestinationHashMismatch' }
            if (Test-Path -LiteralPath $policy.BackupPath) { throw 'BackupCollision' }
            $result.PlannedBytes=$approved.Length
            if ($Mode -eq 'Preview') { $result.Status='Skipped'; $result.Reason='PreviewOnly' }
            else {
                # Write the existing, exclusively locked file rather than rename
                # paths. This preserves its identity, owner and DACL, but is not
                # atomic: interruption may leave partial bytes. Back up first.
                $originalAcl=$destination.GetAccessControl()
                $aclText=$originalAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
                $backupAcl=New-Object Security.AccessControl.FileSecurity
                $backupAcl.SetSecurityDescriptorSddlForm($aclText,[Security.AccessControl.AccessControlSections]::Access)
                $stage='Backup'; $result.MayHaveChanged=$true; $result.OutcomeUncertain=$true; $result.BackupState='Unverified'
                $backup=[MaintenanceFiles]::NewBackup($policy.BackupPath); $held.Add($backup)
                $backup.SetAccessControl($backupAcl)
                $backup.Write($before,0,$before.Length); $backup.Flush($true)
                [MaintenanceFiles]::CopyTimes($destination,$backup)
                if ([MaintenanceFiles]::Hash([MaintenanceFiles]::Read($backup,4096)) -ine $beforeHash -or
                    $backup.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) -cne $aclText) { throw 'BackupNotVerified' }
                $result.BackupState='OriginalVerified'; $result.OutcomeUncertain=$false
                if (Test-Path -LiteralPath (Join-Path $policy.ApplicationRoot 'application.active')) { throw 'ApplicationBecameActive' }
                $stage='Replacement'; $result.OutcomeUncertain=$true; $result.DestinationState='Unknown'
                $destination.Position=0; $destination.Write($approved,0,$approved.Length); $destination.SetLength($approved.Length); $destination.Flush($true)
                $stage='Verification'
                if ([MaintenanceFiles]::Hash([MaintenanceFiles]::Read($destination,4096)) -ine $policy.SourceSha256 -or
                    $destination.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) -cne $aclText) { throw 'ReplacementNotVerified' }
                $result.DestinationState='ApprovedVerified'; $result.OutcomeUncertain=$false
                $result.WrittenBytes=$approved.Length; $result.Status='Changed'; $result.Reason='ApprovedConfigurationRestored'
            }
        }
        # PRODUCT OPERATION END
    } catch {
        $result.Status='Failed'; $result.Reason=$stage + 'Failed'
    } finally {
        for ($i=$held.Count-1; $i -ge 0; $i--) { $held[$i].Dispose() }
    }
    return [pscustomobject]$result
}

# Run all filesystem/provider I/O in one owned child. Compressing the standalone
# worker keeps EncodedCommand under Windows' command-line length limit. Parameters
# are JSON data, never interpolated as PowerShell code.
$summary=[ordered]@{ Product=$product; Mode=$Mode; Status='Failed'; Reason='WorkerNotStarted'; MayHaveChanged=$false; OutcomeUncertain=$false }
$process=$null; $started=$false; $exitCode=1
try {
    $settings=@{ Mode=$Mode; PolicyPath=$PolicyPath; PolicySha256=$PolicySha256 } | ConvertTo-Json -Compress
    $settings64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($settings))
    $workerBytes=[Text.Encoding]::UTF8.GetBytes($worker.ToString())
    $memory=New-Object IO.MemoryStream
    $zip=New-Object IO.Compression.DeflateStream($memory,[IO.Compression.CompressionMode]::Compress,$true)
    $zip.Write($workerBytes,0,$workerBytes.Length); $zip.Dispose()
    $worker64=[Convert]::ToBase64String($memory.ToArray()); $memory.Dispose()
    $command='$ErrorActionPreference="Stop"; $ProgressPreference="SilentlyContinue"; $b=[Convert]::FromBase64String("'+$worker64+'"); $m=New-Object IO.MemoryStream(,$b); $d=New-Object IO.Compression.DeflateStream($m,[IO.Compression.CompressionMode]::Decompress); $r=New-Object IO.StreamReader($d); $w=[scriptblock]::Create($r.ReadToEnd()); $r.Dispose(); $s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$settings64+'")) | ConvertFrom-Json; & $w $s | ConvertTo-Json -Compress -Depth 4'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments='-NoLogo -NoProfile -NonInteractive -EncodedCommand '+$encoded
    if (($start.FileName.Length+$start.Arguments.Length+4) -ge 32767) { throw 'WorkerTooLong' }
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    if (-not $process.Start()) { throw 'WorkerStartFailed' }; $started=$true
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
        $summary.Reason='WorkerTimeout'; $process.Kill()
        if (-not $process.WaitForExit(2000)) { $summary.Reason='WorkerStopUnconfirmed' }
        $summary.MayHaveChanged=($Mode -eq 'Apply'); $summary.OutcomeUncertain=$summary.MayHaveChanged
    } else {
        if ($process.ExitCode -ne 0 -or -not $stdout.Wait(2000) -or -not $stderr.Wait(2000) -or
            $stdout.Result.Length -gt 3500 -or $stderr.Result.Length -ne 0) { throw 'InvalidWorkerOutput' }
        $child=$stdout.Result | ConvertFrom-Json
        if ($child -isnot [pscustomobject] -or $child.Product -cne $product -or $child.Mode -cne $Mode -or
            $child.Status -notin @('Changed','Already correct','Skipped','Failed') -or $child.Reason -notmatch '^[A-Za-z]{1,80}$' -or
            $child.MayHaveChanged -isnot [bool] -or $child.OutcomeUncertain -isnot [bool]) { throw 'InvalidWorkerSchema' }
        $summary=$child
        if ($summary.Status -ne 'Failed') { $exitCode=0 }
    }
} catch {
    $summary=[ordered]@{ Product=$product; Mode=$Mode; Status='Failed'; Reason='WorkerFailed'; MayHaveChanged=($started -and $Mode -eq 'Apply'); OutcomeUncertain=($started -and $Mode -eq 'Apply') }
    if ($null -ne $process -and $started) {
        try { if (-not $process.HasExited) { $process.Kill(); if(-not $process.WaitForExit(2000)) { $summary.Reason='WorkerStopUnconfirmed' } } }
        catch { $summary.Reason='WorkerStopUnconfirmed' }
    }
} finally { if ($null -ne $process) { $process.Dispose() } }
$json=$summary | ConvertTo-Json -Compress -Depth 4
if ([Text.Encoding]::UTF8.GetByteCount($json) -ge 4096) { $json='{"Status":"Failed","Reason":"OutputTooLarge","MayHaveChanged":true,"OutcomeUncertain":true}'; $exitCode=1 }
$json
exit $exitCode
