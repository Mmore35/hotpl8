$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/common.ps1')
. (Join-Path $root 'src/config.ps1')
. (Join-Path $root 'src/providers/claude-plans.ps1')
$dir=Join-Path ([IO.Path]::GetTempPath()) ('hotpl8-plans-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$now=[datetimeoffset]::Parse('2026-09-14T12:00:00Z')
$account=[pscustomobject]@{number=1;email='fictional@example.invalid';organizationUuid='fictional-org'}
$script:calls=0;$script:profile='claude-pro';$script:status='detected'
$reader={param($slots) $script:calls++;[pscustomobject]@{schemaVersion=1;accounts=@([pscustomobject]@{slot=1;identityKey=(Get-Hotpl8Hash ($account.email+'|'+$account.organizationUuid));status=$script:status;profile=$script:profile;retryAfterSeconds=3600})}}
function Assert($value){if(-not $value){throw 'Plan detection assertion failed'}}
try{
    $first=Read-Hotpl8ClaudePlans @($account) $dir '' $now $reader
    Assert ($first.'1'.profile -eq 'claude-pro' -and $script:calls -eq 1)
    $cached=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddMinutes(5) $reader
    Assert ($cached.'1'.profile -eq 'claude-pro' -and $script:calls -eq 1)
    'PASS cached discovery does not poll on every tick'
    $script:profile='claude-max-5x'
    $updated=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddMinutes(16) $reader
    Assert ($updated.'1'.profile -eq 'claude-max-5x' -and $script:calls -eq 2)
    'PASS plan changes refresh automatically'
    $account.email='replacement@example.invalid'
    $updated=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddMinutes(17) $reader
    Assert ($script:calls -eq 3 -and $updated.'1'.identityKey -ne $first.'1'.identityKey)
    'PASS slot reuse invalidates the previous identity cache'
    $script:status='rate_limited'
    $limited=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddMinutes(33) $reader
    $null=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddMinutes(55) $reader
    Assert ($script:calls -eq 4 -and $limited.'1'.status -eq 'rate_limited' -and -not $limited.'1'.profile)
    'PASS rate limits preserve backoff and do not claim stale detection'
    $malicious={param($slots) [pscustomobject]@{schemaVersion=1;accounts=@([pscustomobject]@{slot=1;identityKey='foreign';status='detected';profile='claude-max-20x';label='secret'})}}
    $foreign=Read-Hotpl8ClaudePlans @($account) $dir '' $now.AddHours(3) $malicious
    Assert (-not $foreign.'1'.profile -and -not $foreign.'1'.label)
    'PASS foreign helper results cannot label an account'
    $script:status='detected'
    $missing=[pscustomobject]@{number=1;email=$account.email}
    $nativeBinding=$updated.'1'.identityKey
    $organizationReader={param($slots) [pscustomobject]@{schemaVersion=1;accounts=@([pscustomobject]@{slot=1;identityKey=$nativeBinding;status='detected';profile='claude-pro'})}}.GetNewClosure()
    $unsupported=Read-Hotpl8ClaudePlans @($missing) $dir '' $now.AddHours(4) $organizationReader
    Assert (-not $unsupported.'1'.profile -and $unsupported.'1'.status -eq 'unavailable')
    'PASS inventory without organization identity stays unknown'
    $part=[pscustomobject]@{};$detected=$first.'1'
    $auto=Get-Hotpl8AccountCapacity $part 1 claude '' $detected $now
    Assert ($auto.profile -eq 'claude-pro' -and $null -eq $auto.weekly -and $null -eq $auto.fiveHour)
    $part|Add-Member NoteProperty capacity @{ '1'=@{profile='claude-max-20x';weekly=7;fiveHour=2} }
    $manual=Get-Hotpl8AccountCapacity $part 1 claude '' $detected $now
    Assert ($manual.weekly -eq 7 -and $manual.fiveHour -eq 2 -and $manual.profile -eq 'claude-max-20x')
    Assert (-not (Test-Hotpl8DetectedPlan $detected $now.AddHours(1)))
    'PASS automatic profile preserves unknown conversions and explicit overrides'
    $text=Get-Content (Join-Path $dir 'claude-plans.json') -Raw
    Assert ($text -notmatch 'example.invalid|fictional-org|secret')
    'PASS cache contains no email, organization ID or raw provider content'
}finally{
    $full=[IO.Path]::GetFullPath($dir)
    if($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $full -Leaf) -match '^hotpl8-plans-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
