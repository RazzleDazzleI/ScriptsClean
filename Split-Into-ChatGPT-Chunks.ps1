<#  Split a big .txt into ~15,000-word chunks (ChatGPT-friendly)
    - Input:  C:\Scripts\Thomas DeLauer.txt
    - Output: C:\Scripts\ThomasDeLauer_Segments\ThomasDeLauer_Part###.txt
#>

$InputFile      = "C:\Scripts\Thomas DeLauer.txt"
$OutputDir      = "C:\Scripts\ThomasDeLauer_Segments"
$WordsPerChunk  = 15000     # adjust if needed (12k–18k safe)

# --- Prep output folder ---
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Clear old parts from previous runs
Get-ChildItem -Path $OutputDir -Filter "ThomasDeLauer_Part*.txt" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# --- Helpers ---
function New-PartWriter {
    param([int]$Index)
    $fname = "ThomasDeLauer_Part{0:D3}.txt" -f $Index
    $path  = Join-Path $OutputDir $fname
    $sw = New-Object System.IO.StreamWriter($path, $false, [System.Text.Encoding]::UTF8)
    return @{ Writer = $sw; Path = $path }
}

function Count-WordsInLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return 0 }
    return ($Line -split '\s+' | Where-Object { $_ -ne "" }).Count
}

# --- Stream & split ---
$partIndex   = 1
$wordsInPart = 0
$opened      = $false
$created     = @()

try {
    $sr = New-Object System.IO.StreamReader($InputFile, [System.Text.Encoding]::UTF8, $true)
    try {
        $slot = New-PartWriter -Index $partIndex
        $writer = $slot.Writer
        $opened = $true
        $created += $slot.Path
        Write-Host ("Creating {0}" -f (Split-Path $slot.Path -Leaf))

        while (($line = $sr.ReadLine()) -ne $null) {
            $writer.WriteLine($line)
            $wordsInPart += Count-WordsInLine $line

            if ($wordsInPart -ge $WordsPerChunk) {
                $writer.Flush(); $writer.Close()
                $opened = $false
                Write-Host ("Finalized {0} (~{1} words)" -f (Split-Path $slot.Path -Leaf), $wordsInPart)

                $partIndex++
                $wordsInPart = 0

                $slot = New-PartWriter -Index $partIndex
                $writer = $slot.Writer
                $opened = $true
                $created += $slot.Path
                Write-Host ("Creating {0}" -f (Split-Path $slot.Path -Leaf))
            }
        }
    }
    finally {
        if ($opened) { $writer.Flush(); $writer.Close() }
        $sr.Close()
    }
}
catch {
    Write-Error $_
    throw
}

# Remove trailing empty file if created
$last = Get-ChildItem -Path $OutputDir -Filter "ThomasDeLauer_Part*.txt" | Sort-Object Name | Select-Object -Last 1
if ($last -and $last.Length -eq 0) {
    Remove-Item $last.FullName -Force
    Write-Host ("Removed empty {0}" -f $last.Name)
}

# --- Summary ---
Write-Host "`nDone. Files created in: $OutputDir"
(Get-ChildItem -Path $OutputDir -Filter "ThomasDeLauer_Part*.txt" | Sort-Object Name |
    Select-Object Name, Length) | Format-Table -Auto
