#requires -Version 5.1
<#
.SYNOPSIS
Removes only policy-approved disposable staging files. Preview is the default.
.DESCRIPTION
Standalone offline Windows PowerShell 5.1. Requires a reviewed local JSON policy
and its independently approved SHA256. See staging-cleanup.md before use.
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
$product = 'mecm-staging-cleanup'
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
    $result = [ordered]@{ Product='mecm-staging-cleanup'; Mode=$Mode; Status='Failed'; Reason='InspectionFailed';
        ExaminedCount=0; EligibleCount=0; RemovedCount=0; RetainedCount=0; PlannedBytes=[long]0; RemovedBytes=[long]0;
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
        $policy=Get-Policy @('SchemaVersion','Approved','ApprovalReference','ApplicationId','Root','ActivityProtocol','FileNamePatterns','MinimumAgeDays','MaximumEntries','MaximumDeleteBytes','ActivityMarkers','ProcessNames')
        Assert-String $policy.Root '^[A-Za-z]:\\'
        [MaintenanceFiles]::Scope($policy.Root)
        if ([IO.Path]::GetFileName($policy.Root) -cne 'DisposableStaging' -or
            [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($policy.Root)) -cne $policy.ApplicationId) { throw 'ApplicationScopeMismatch' }
        Assert-StringList $policy.FileNamePatterns '^[A-Za-z0-9-]{1,32}-\*\.disposable$' 8
        Assert-StringList $policy.ActivityMarkers '^[A-Za-z0-9-]{1,32}\.active$'
        Assert-StringList $policy.ProcessNames '^[A-Za-z][A-Za-z0-9_-]{1,39}$'
        Assert-Integer $policy.MinimumAgeDays 1 3650
        Assert-Integer $policy.MaximumEntries 1 500
        Assert-Integer $policy.MaximumDeleteBytes 1 1073741824
        foreach ($pattern in $policy.FileNamePatterns) {
            if ($pattern -match '(?i)(log|evidence|package|active)') { throw 'ProtectedPattern' }
        }
        Lock-Parents $policy.Root $true
        $guard=[MaintenanceFiles]::Open((Join-Path $policy.Root 'maintenance.guard'),$false,$false); $held.Add($guard)
        function Assert-Inactive {
            foreach ($marker in $policy.ActivityMarkers) {
                if (Test-Path -LiteralPath (Join-Path $policy.Root $marker)) { throw 'ActivityMarkerPresent' }
            }
            $processNames=@(Get-Process -ErrorAction Stop | Select-Object -ExpandProperty ProcessName)
            foreach ($name in $policy.ProcessNames) { if ($processNames -icontains $name) { throw 'ApplicationRunning' } }
        }
        $stage='ActivityCheck'; Assert-Inactive
        $stage='Enumeration'
        $candidates=New-Object 'Collections.Generic.List[object]'
        $cutoff=[datetime]::UtcNow.AddDays(-$policy.MinimumAgeDays)
        # Lazy top-level enumeration: never recurse or enumerate an unbounded tree.
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($policy.Root)) {
            $result.ExaminedCount++
            if ($result.ExaminedCount -gt $policy.MaximumEntries) { throw 'EntryLimitExceeded' }
            $leaf=[IO.Path]::GetFileName($path)
            $matches=@($policy.FileNamePatterns | Where-Object { $leaf -clike $_ })
            if ($matches.Count -ne 1 -or $leaf -match '(?i)(log|evidence|package|active)') { $result.RetainedCount++; continue }
            $file=$null
            try {
                $file=[MaintenanceFiles]::Open($path,$false,($Mode -eq 'Apply'))
                $info=[MaintenanceFiles]::Inspect($file.SafeFileHandle)
                $written=[datetime]::FromFileTimeUtc($info.Written)
                $created=[datetime]::FromFileTimeUtc($info.Created)
                if ($written -lt [datetime]'1970-01-01Z' -or $created -lt [datetime]'1970-01-01Z' -or
                    $written -ge $cutoff -or $created -ge $cutoff) { $result.RetainedCount++; $file.Dispose(); continue }
                $result.EligibleCount++; $result.PlannedBytes += $file.Length
                if ($result.PlannedBytes -gt $policy.MaximumDeleteBytes) { throw 'ByteLimitExceeded' }
                $held.Add($file)
                $candidates.Add([pscustomobject]@{ Path=$path; Stream=$file; Size=$file.Length })
            } catch {
                if ($null -ne $file) { $file.Dispose() }
                # An eligible-looking file that cannot be proven safe fails the
                # whole preflight. Nothing is removed until every entry passes.
                throw
            }
        }
        if ($Mode -eq 'Preview') { $result.Status='Skipped'; $result.Reason='PreviewOnly' }
        elseif ($candidates.Count -eq 0) { $result.Status='Already correct'; $result.Reason='NoEligibleFiles' }
        else {
            foreach ($candidate in $candidates) {
                $stage='ActivityCheck'; Assert-Inactive
                $stage='Deletion'; $result.MayHaveChanged=$true; $result.OutcomeUncertain=$true
                [MaintenanceFiles]::Delete($candidate.Stream)
                $candidate.Stream.Dispose()
                $stage='Verification'
                if (Test-Path -LiteralPath $candidate.Path) { throw 'DeletionNotConfirmed' }
                $result.RemovedCount++; $result.RemovedBytes += $candidate.Size; $result.OutcomeUncertain=$false
            }
            $result.Status='Changed'; $result.Reason='ApprovedDisposableFilesRemoved'
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
