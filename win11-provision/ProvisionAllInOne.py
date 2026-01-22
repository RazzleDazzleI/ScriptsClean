import ctypes, subprocess, sys, os, logging, textwrap, shlex
from pathlib import Path

LOG_DIR = Path(r"C:\ProgramData\DRM\Provision\Logs")
LOG_DIR.mkdir(parents=True, exist_ok=True)
log_path = LOG_DIR / f"AllInOne_{__import__('datetime').datetime.now():%Y%m%d_%H%M%S}.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.FileHandler(log_path, encoding="utf-8"), logging.StreamHandler(sys.stdout)]
)
log = logging.getLogger("provision")

def run(cmd:list[str] | str, check=True):
    """Run a command (list preferred). Log stdout/stderr."""
    if isinstance(cmd, str):
        shell=True; printable = cmd
    else:
        shell=False; printable = " ".join(shlex.quote(c) for c in cmd)
    log.info("RUN: %s", printable)
    r = subprocess.run(cmd, shell=shell, capture_output=True, text=True)
    if r.stdout: log.info(r.stdout.strip())
    if r.stderr: log.warning(r.stderr.strip())
    if check and r.returncode != 0:
        raise RuntimeError(f"Command failed rc={r.returncode}: {printable}\n{r.stderr}")
    return r

def ps(ps_command:str, check=True):
    """Run a PowerShell command safely without string-escaping headaches."""
    return run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps_command], check=check)

def ensure_admin():
    try:
        if ctypes.windll.shell32.IsUserAnAdmin():
            return
    except Exception:
        pass
    # re-launch elevated
    params = " ".join(f'"{a}"' for a in sys.argv)
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, params, None, 1)
    sys.exit(0)

def winget_ready()->bool:
    try:
        run(["winget","--version"])
        return True
    except Exception:
        return False

def winget_install(pkg_id:str, dry=False):
    log.info("[winget] install %s", pkg_id)
    if dry: return
    try:
        # Warm sources once (ignore failure)
        subprocess.run(["winget","source","update"], capture_output=True, text=True)
    except Exception:
        pass
    run(["winget","install","-e","--id",pkg_id,"--silent","--accept-source-agreements","--accept-package-agreements"], check=False)

def get_user_sids()->list[str]:
    out = ps("Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\\Users\\*' } | Select-Object -ExpandProperty SID", check=False)
    sids = [ln.strip() for ln in (out.stdout or "").splitlines() if ln.strip()]
    return sids

def remove_bloat(dry=False):
    log.info("Bloat removal: start")
    apps_to_remove = [
        "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.Getstarted",
        "Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MicrosoftStickyNotes","Microsoft.People",
        # "Microsoft.ScreenSketch",  # Snipping Tool (keep)
        "Microsoft.WindowsAlarms","Microsoft.WindowsMaps",
        "Microsoft.XboxGamingOverlay","Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.Windows.Photos",
        "Microsoft.WindowsSoundRecorder","Microsoft.Whiteboard","Microsoft.MicrosoftJournal",
        "Microsoft.Windows.DevHome","Microsoft.OutlookForWindows",
        "Microsoft.OneNote","Microsoft.Office.OneNote","Microsoft.Office.Desktop.LanguagePack",
    ]
    non_removable = {"Microsoft.XboxGameCallableUI"}
    sids = get_user_sids()

    for app in apps_to_remove:
        if app in non_removable:
            log.info("Skip non-removable: %s", app); continue

        # 1) deprovision (future users)
        cmd_prov = textwrap.dedent(f"""
            $prov = Get-AppxProvisionedPackage -Online | Where-Object {{ $_.DisplayName -like "{app}*" }};
            if($prov){{ foreach($p in $prov){{ Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null }} }}
        """).strip()
        if dry: log.info("DRY: deprovision %s", app)
        else: ps(cmd_prov, check=False)

        # 2) remove per existing SID
        if dry:
            log.info("DRY: remove %s for SIDs: %s", app, ", ".join(sids))
        else:
            # find all installed instances
            out = ps(f"Get-AppxPackage -AllUsers -Name {app} -ErrorAction SilentlyContinue", check=False)
            if out.stdout:
                # For each found package, remove per SID
                cmd = textwrap.dedent(f"""
                    $pkgs = Get-AppxPackage -AllUsers -Name {app} -ErrorAction SilentlyContinue;
                    if($pkgs){{
                      foreach($p in $pkgs){{
                        foreach($sid in @({", ".join(f"'{s}'" for s in sids)})){{
                          try {{ Remove-AppxPackage -Package $p.PackageFullName -User $sid -ErrorAction Continue }} catch {{ }}
                        }}
                      }}
                    }}
                """).strip()
                ps(cmd, check=False)

    log.info("Bloat removal: done")

def cleanup_teams_classic(dry=False):
    log.info("Teams classic cleanup: start")
    if dry:
        log.info("DRY: remove Teams Machine-Wide Installer MSI and per-user caches")
        return
    # Remove Teams Machine-Wide Installer (MSI)
    ps(textwrap.dedent(r"""
        $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*');
        $mw = Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' };
        foreach($app in $mw){
          $cmd = $app.UninstallString;
          if($cmd -match 'MsiExec\.exe.*?/I\{([0-9A-F\-]+)\}'){ $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
          elseif($cmd -match 'MsiExec\.exe.*?/X\{([0-9A-F\-]+)\}'){ $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
          else { $cmd = "$cmd /qn /norestart" }
          Start-Process cmd.exe "/c $cmd" -Wait -WindowStyle Hidden | Out-Null
        }
        $profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' };
        foreach($u in $profiles){
          $upd = Join-Path $u.LocalPath 'AppData\Local\Microsoft\Teams\Update.exe';
          if(Test-Path $upd){ Start-Process $upd -ArgumentList '--uninstall -s' -Wait -WindowStyle Hidden | Out-Null }
          foreach($d in @('AppData\Local\Microsoft\Teams','AppData\Roaming\Microsoft\Teams')){
            $p = Join-Path $u.LocalPath $d; if(Test-Path $p){ Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
          }
        }
        $cache = 'C:\Program Files (x86)\Teams Installer'; if(Test-Path $cache){ Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue }
    """).strip(), check=False)
    log.info("Teams classic cleanup: done")

def enable_netfx3(dry=False):
    log.info("Enable NetFx3")
    if dry: return
    run("DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart", check=False)

def apply_policies(dry=False):
    log.info("Apply policies")
    if dry: return
    import winreg
    items = [
        ("HKLM","SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent","DisableWindowsConsumerFeatures", winreg.REG_DWORD, 1),
        ("HKLM","SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","SilentInstalledAppsEnabled", winreg.REG_DWORD, 0),
        ("HKLM","SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","ContentDeliveryAllowed", winreg.REG_DWORD, 0),
        ("HKLM","SOFTWARE\\Policies\\Microsoft\\WindowsStore","AutoDownload", winreg.REG_DWORD, 2),
    ]
    H = {"HKLM": winreg.HKEY_LOCAL_MACHINE, "HKCU": winreg.HKEY_CURRENT_USER}
    for hive, path, name, typ, val in items:
        with winreg.CreateKeyEx(H[hive], path, 0, winreg.KEY_SET_VALUE) as k:
            winreg.SetValueEx(k, name, 0, typ, val)

def set_timezone(tz:str|None, dry=False):
    if not tz: return
    log.info("Set timezone: %s", tz)
    if dry: return
    ps(f"Set-TimeZone -Name '{tz}'", check=False)

def ensure_local_admin(user:str, password:str|None, dry=False):
    if not password:
        password = os.environ.get("DRM_ADMIN_PWD","")
    if not password:
        log.warning("No admin password provided; skipping local admin creation for %s", user); return
    log.info("Ensure local admin: %s", user)
    if dry: return
    ps(textwrap.dedent(f"""
        $u = Get-LocalUser -Name '{user}' -ErrorAction SilentlyContinue;
        $sec = ConvertTo-SecureString '{password}' -AsPlainText -Force;
        if(-not $u){{ New-LocalUser -Name '{user}' -Password $sec -NoPasswordExpiration -UserMayNotChangePassword:$true }}
        else        {{ Set-LocalUser -Name '{user}' -Password $sec }}
        Add-LocalGroupMember -Group 'Administrators' -Member '{user}' -ErrorAction SilentlyContinue
    """).strip(), check=False)

def parse_args():
    import argparse
    p = argparse.ArgumentParser(description="DRM Win11 Provisioner (Python)")
    p.add_argument("--admin-user", default="drmadministrator")
    p.add_argument("--admin-password", default=None)
    p.add_argument("--timezone", default=None)
    p.add_argument("--install-chrome", action="store_true")
    p.add_argument("--install-reader", action="store_true")
    p.add_argument("--install-7zip", action="store_true")
    p.add_argument("--install-notepadpp", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()

def main():
    ensure_admin()
    args = parse_args()
    log.info("Start (dry-run=%s) log=%s", args.dry_run, log_path)

    set_timezone(args.timezone, dry=args.dry_run)
    cleanup_teams_classic(dry=args.dry_run)
    remove_bloat(dry=args.dry_run)
    enable_netfx3(dry=args.dry_run)
    apply_policies(dry=args.dry_run)

    # Winget installs
    if not args.dry_run and not winget_ready():
        log.warning("winget not available; skipping installs.")
    else:
        winget_install("Microsoft.Teams", dry=args.dry_run)
        if args.install_chrome:    winget_install("Google.Chrome", dry=args.dry_run)
        if args.install_reader:    winget_install("Adobe.Acrobat.Reader.64-bit", dry=args.dry_run)
        if args.install_7zip:      winget_install("7zip.7zip", dry=args.dry_run)
        if args.install_notepadpp: winget_install("Notepad++.Notepad++", dry=args.dry_run)

    ensure_local_admin(args.admin_user, args.admin_password, dry=args.dry_run)

    log.info("All done.")
    log.info("Log saved to %s", log_path)

if __name__ == "__main__":
    main()
