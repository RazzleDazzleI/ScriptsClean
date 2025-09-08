from cryptography.fernet import Fernet

# Generate a secure Fernet key
key = Fernet.generate_key()

# Save it to key.key
with open("key.key", "wb") as key_file:
    key_file.write(key)

print("New Fernet key saved to key.key")
