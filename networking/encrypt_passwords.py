from cryptography.fernet import Fernet

# Load your existing key
with open("key.key", "rb") as key_file:
    key = key_file.read()

# Encrypt your password
fernet = Fernet(key)

plain_password = b"0r@ng3B@tt3ry"  # <--- CHANGE THIS
second_password = b"m@N@gedD3VIC3"

encrypted1 = fernet.encrypt(plain_password)
encrypted2 = fernet.encrypt(second_password)

print("Encrypted 1:", encrypted1.decode())
print("Encrypted 2:", encrypted2.decode())
