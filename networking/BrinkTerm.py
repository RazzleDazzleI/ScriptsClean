import tkinter as tk
from tkinter import messagebox
import psutil
import socket
import subprocess
import os
import ctypes
import sys
import shutil
import time
import datetime
import glob

# === Admin Check ===
def is_admin():
    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False

if not is_admin():
    ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, ' '.join([f'"{arg}"' for arg in sys.argv]), None, 1)
    sys.exit()

# === Enable all disabled Ethernet interfaces ===
def enable_ethernet_adapters():
    try:
        subprocess.run(
            'powershell -Command "Get-NetAdapter | Where-Object { $_.Status -eq \'Disabled\' -and $_.Name -like \'*Ethernet*\' } | Enable-NetAdapter -Confirm:$false"',
            shell=True
        )
    except Exception:
        pass

enable_ethernet_adapters()

# === Disable Wi-Fi and Turn off Airplane Mode ===
def disable_wifi_and_check_airplane():
    log_entries = []
    wifi_found = False
    airplane_mode_enabled = False

    # Disable Wi-Fi if active
    for iface, stats in psutil.net_if_stats().items():
        if "wi-fi" in iface.lower():
            wifi_found = True
            if stats.isup:
                log_entries.append(f"Wi-Fi interface '{iface}' was ON – disabling...")
                subprocess.run(f'netsh interface set interface "{iface}" admin=disabled', shell=True)
            else:
                log_entries.append(f"Wi-Fi interface '{iface}' is already OFF.")
    if not wifi_found:
        log_entries.append("No Wi-Fi interface found.")

    # Detect Airplane Mode via registry
    try:
        output = subprocess.check_output(
            r'reg query "HKLM\System\CurrentControlSet\Control\RadioManagement\SystemRadioState"',
            shell=True, text=True
        )
        if "0x1" in output:
            log_entries.append("Airplane Mode is ON.")
            airplane_mode_enabled = True
        else:
            log_entries.append("Airplane Mode is OFF.")
    except Exception as e:
        log_entries.append(f"Error checking Airplane Mode: {e}")

    return log_entries, airplane_mode_enabled

# === Emergency Prompt ===
emergency_root = tk.Tk()
emergency_root.withdraw()

def show_emergency_prompt():
    emergency_root.deiconify()
    emergency_root.title("Emergency Contact")
    emergency_root.geometry("400x150")
    emergency_root.resizable(False, False)

    label = tk.Label(emergency_root, text="Please call I.T. Emergency Support\n(402) 938-5180 before continuing.",
                     fg="red", font=("Segoe UI", 12, "bold"), justify="center")
    label.pack(pady=20)

    btn_frame = tk.Frame(emergency_root)
    btn_frame.pack()

    def on_continue():
        emergency_root.destroy()

    def on_cancel():
        emergency_root.destroy()
        sys.exit()

    tk.Button(btn_frame, text="Continue", bg="green", fg="white", width=12, command=on_continue).pack(side="left", padx=10)
    tk.Button(btn_frame, text="Cancel", bg="red", fg="white", width=12, command=on_cancel).pack(side="right", padx=10)

    emergency_root.mainloop()

show_emergency_prompt()

# === Detect Ethernet Interface ===
def get_ethernet_interface():
    for iface, addrs in psutil.net_if_addrs().items():
        if "ethernet" in iface.lower() and iface.lower() != "loopback":
            for addr in addrs:
                if addr.family == socket.AF_INET:
                    return iface
    return None

ethernet_interface = get_ethernet_interface()

# === Setup Logging ===
timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
log_folder = r"C:\Temp\brink_term_logs"
os.makedirs(log_folder, exist_ok=True)
log_path = os.path.join(log_folder, f"log_{timestamp}.txt")
event_path = os.path.join(log_folder, f"event_{timestamp}.evtx")

def cleanup_old_logs():
    for pattern in ["log_*.txt", "event_*.evtx"]:
        for file in glob.glob(os.path.join(log_folder, pattern)):
            if os.path.isfile(file):
                file_time = os.path.getmtime(file)
                if time.time() - file_time > 30 * 86400:
                    os.remove(file)

cleanup_old_logs()

# === Write unified network diagnostics ===
def write_diagnostics_log(extra_entries=[]):
    with open(log_path, "w") as f:
        f.write(f"--- Unified Network Snapshot ({timestamp}) ---\n\n")

        for iface, addrs in psutil.net_if_addrs().items():
            f.write(f"[Interface: {iface}]\n")
            for addr in addrs:
                f.write(f" - {addr.family.name if hasattr(addr.family, 'name') else addr.family}: {addr.address}\n")
            f.write("\n")

        f.write("--- Network connections:\n")
        for conn in psutil.net_connections(kind='inet'):
            try:
                laddr = f"{conn.laddr.ip}:{conn.laddr.port}" if conn.laddr else "None"
                raddr = f"{conn.raddr.ip}:{conn.raddr.port}" if conn.raddr else "None"
                status = conn.status
                f.write(f"{laddr} -> {raddr} | status: {status}\n")
            except Exception:
                continue

        f.write("\n=== IPCONFIG /ALL ===\n")
        f.write(subprocess.getoutput("ipconfig /all"))
        f.write("\n\n=== ROUTE PRINT ===\n")
        f.write(subprocess.getoutput("route print"))
        f.write("\n\n=== NETSH INTERFACE SHOW INTERFACE ===\n")
        f.write(subprocess.getoutput("netsh interface show interface"))
        f.write("\n\n--- Startup Checks ---\n")
        for line in extra_entries:
            f.write(line + "\n")

# === Export Event Logs ===
def export_event_logs():
    try:
        subprocess.run(f'wevtutil epl System "{event_path}" /ow:true /q:"*[System[TimeCreated[timediff(@SystemTime) <= 86400000]]]"', shell=True)
    except Exception as e:
        with open(log_path, "a") as f:
            f.write(f"\nError exporting event logs: {e}\n")

# === GUI ===
root = tk.Tk()
root.title("Brink TermCFG")
root.geometry("772x517")
root.resizable(False, False)
root.attributes("-topmost", True)

main_frame = tk.Frame(root)
main_frame.pack(expand=True)

# === Status Check ===
def get_status_label():
    try:
        output = subprocess.check_output('reg query "HKLM\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState"', shell=True, text=True)
        if "0x1" in output:
            return "AIRPLANE MODE ENABLED", "blue"
    except Exception:
        pass

    if ethernet_interface:
        return "ETHERNET CONNECTED", "green"
    else:
        return "WARNING!", "red"

status_text, status_color = get_status_label()
status_label = tk.Label(main_frame, text=status_text, fg=status_color, font=("Segoe UI", 14, "bold"))
status_label.pack(pady=10)

# === Register Buttons ===
selected_register = tk.StringVar(value="")

def create_register_button(text):
    def on_click():
        for btn in register_buttons:
            btn.configure(bg="SystemButtonFace")
        selected_register.set(text)
        button.configure(bg="lightblue")
    button = tk.Button(main_frame, text=text, width=40, height=2, font=("Segoe UI", 12), command=on_click)
    return button

register_buttons = []
for i in range(1, 6):
    btn = create_register_button(f"Register {i}")
    btn.pack(pady=5)
    register_buttons.append(btn)

# === On Submit ===
def on_okay():
    if not selected_register.get():
        messagebox.showwarning("Select Register", "Please select a register before proceeding.")
        return

    if not ethernet_interface:
        messagebox.showerror("Error", "No Ethernet NIC available.")
        return

    register_settings = {
        "Register 1": ("192.168.2.11", "255.255.255.0", "192.168.2.1"),
        "Register 2": ("192.168.2.12", "255.255.255.0", "192.168.2.1"),
        "Register 3": ("192.168.2.13", "255.255.255.0", "192.168.2.1"),
        "Register 4": ("192.168.2.14", "255.255.255.0", "192.168.2.1"),
        "Register 5": ("192.168.2.15", "255.255.255.0", "192.168.2.1"),
    }

    ip, subnet, gateway = register_settings[selected_register.get()]
    dns1, dns2 = "8.8.8.8", "8.8.4.4"
    hostname = f"REG-{selected_register.get()[-1]}"

    try:
        subprocess.run(["netsh", "interface", "ip", "set", "address", ethernet_interface, "static", ip, subnet, gateway], check=True)
        subprocess.run(["netsh", "interface", "ip", "set", "dns", ethernet_interface, "static", dns1], check=True)
        subprocess.run(["netsh", "interface", "ip", "add", "dns", ethernet_interface, dns2, "index=2"], check=True)
        subprocess.run(f'wmic computersystem where name="%COMPUTERNAME%" call rename name="{hostname}"', shell=True)
    except subprocess.CalledProcessError as e:
        messagebox.showerror("Error", f"Failed to apply settings:\n{e}")
        return

    export_event_logs()
    write_diagnostics_log(extra_entries=startup_log_entries)
    os.system("shutdown /r /t 1")
    root.destroy()

okay_button = tk.Button(main_frame, text="Okay!", width=40, height=2, bg="green", fg="white", font=("Segoe UI", 12), command=on_okay)
okay_button.pack(pady=20)

root.mainloop()
