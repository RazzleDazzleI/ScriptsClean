from cryptography.fernet import Fernet
import paramiko
import time

# ---- Setup ----
fortigate_ip = input("FortiGate IP: ")
username = input("Username: ")

# Load encryption key
with open("key.key", "rb") as f:
    key = f.read()

fernet = Fernet(key)

# Encrypted passwords (replace with your actual encrypted values)
encrypted_passwords = [
    b"gAAAAABoOcPpT-h84sn015zbHtwBVt9OqjtO3LjQbBo-tHTXajq6i2X-MUkDcO8zrUXA4oPapLVmTeMwdWcqn-44j7D4OJR-kg==",  # First password
    b"gAAAAABoOcPpBCS7fX8kZmJxDLgjJvfjoo1UP0l59_FAPINTQA2J5xoQesJqKcKxJLEOfPOzb5uZ_UxcgSlT8p6fGfi5bTx3tg=="   # Second password
]

# ---- Commands to Send ----
commands = [
    "config system sdwan",
    "config health-check",
    "edit InternetCheck",
    "set server 8.8.8.8 1.1.1.1",
    "set protocol ping",
    "set interface wan1",
    "set failtime 5",
    "set recoverytime 5",
    "next",
    "end",
    "config service",
    "edit 1",
    "set name DefaultRoute",
    "set dst 0.0.0.0/0",
    "set health-check InternetCheck",
    "set priority 1 2",
    "next",
    "end",
    "end",
    "execute backup config flash"
]

# ---- Attempt Login with Each Password ----
def push_config():
    for enc_pass in encrypted_passwords:
        password = fernet.decrypt(enc_pass).decode()
        try:
            print(f"\nTrying to connect to {fortigate_ip} with one of the passwords...")
            ssh = paramiko.SSHClient()
            ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            ssh.connect(fortigate_ip, username=username, password=password)

            shell = ssh.invoke_shell()
            for cmd in commands:
                shell.send(cmd + '\n')
                time.sleep(1)

            print(f"[✓] Config applied successfully to {fortigate_ip}.")
            ssh.close()
            return

        except paramiko.AuthenticationException:
            print(f"[!] Password failed, trying next...")

        except Exception as e:
            print(f"[✗] Other error: {e}")
            return

    print("[✗] All passwords failed.")

push_config()
