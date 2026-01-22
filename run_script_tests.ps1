# Set root directory and log path
$root = "C:\Scripts"
$logFile = "$root\script_test_log.txt"
Remove-Item $logFile -ErrorAction SilentlyContinue

# Define which script extensions to test
$extensionsToTest = @("*.ps1", "*.py")

# Walk through script files
foreach ($ext in $extensionsToTest) {
    Get-ChildItem -Path $root -Recurse -Filter $ext -File |
        Where-Object { $_.Name -ne "run_script_tests.ps1" } |
        ForEach-Object {
            $script = $_.FullName
            $name = $_.Name
            $ext = $_.Extension.ToLower()

            Write-Output "Testing: $name" | Tee-Object -FilePath $logFile -Append

            try {
                $exitCode = 0

                switch ($ext) {
                    ".ps1" {
                        $proc = Start-Process pwsh -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"" -NoNewWindow -PassThru
                        if (-not $proc.WaitForExit(10)) {
                            $proc | Stop-Process -Force
                            Write-Output "TIMEOUT: $name (>10s)`n" | Tee-Object -FilePath $logFile -Append
                            return
                        }
                        $exitCode = $proc.ExitCode
                    }
                    ".py" {
                        $proc = Start-Process python -ArgumentList "`"$script`"" -NoNewWindow -PassThru
                        if (-not $proc.WaitForExit(10)) {
                            $proc | Stop-Process -Force
                            Write-Output "TIMEOUT: $name (>10s)`n" | Tee-Object -FilePath $logFile -Append
                            return
                        }
                        $exitCode = $proc.ExitCode
                    }
                }

                if ($exitCode -eq 0) {
                    Write-Output "PASSED: $name`n" | Tee-Object -FilePath $logFile -Append
                } else {
                    Write-Output "FAILED: $name (Exit code: $exitCode)`n" | Tee-Object -FilePath $logFile -Append
                }
            }
            catch {
                Write-Output ("ERROR running ${name}: $($_)`n") | Tee-Object -FilePath $logFile -Append
            }
        }
}

Write-Host "`n🧪 Test results saved to $logFile"
