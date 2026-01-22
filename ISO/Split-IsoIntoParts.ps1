# Split-IsoIntoParts.ps1
param(
  [Parameter(Mandatory=$true)][string]$SourceIso,
  [string]$OutDir = "$(Split-Path -Path $SourceIso)\parts",
  [int]$PartSizeMB = 900   # keep under Splashtop 1GB limit
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$partSizeBytes = [int64]$PartSizeMB * 1MB
$bufferSize    = 4MB
$buffer        = New-Object byte[] $bufferSize

$baseName = [IO.Path]::GetFileName($SourceIso)
$in       = [IO.File]::OpenRead($SourceIso)
try{
  $i = 1
  while($in.Position -lt $in.Length){
    $outPath = Join-Path $OutDir ("{0}.part{1:000}" -f $baseName, $i)
    $out     = [IO.File]::Create($outPath)
    try{
      $written = 0L
      while(($read = $in.Read($buffer,0,$buffer.Length)) -gt 0){
        $out.Write($buffer,0,$read)
        $written += $read
        if($written -ge $partSizeBytes){ break }
      }
    } finally { $out.Dispose() }
    Write-Host "Wrote $outPath ($([math]::Round($written/1MB)) MB)"
    $i++
  }
} finally { $in.Dispose() }

# Make a SHA-256 file so we can verify after reassembly
$hash = (Get-FileHash -Path $SourceIso -Algorithm SHA256).Hash.ToUpper()
$hashFile = Join-Path $OutDir ($baseName + ".sha256.txt")
$hash | Set-Content -Path $hashFile -Encoding ASCII
Write-Host "SHA-256: $hash"
Write-Host "Parts in: $OutDir"
