import re

SSHD_CONFIG = "/etc/ssh/sshd_config"
WEAK_CIPHERS = ["3des", "arcfour", "aes128-cbc", "blowfish-cbc"]
WEAK_MACS = ["hmac-md5", "hmac-sha1"]

def main():
    with open(SSHD_CONFIG) as f:
        cfg = f.read()
    for cipher in WEAK_CIPHERS:
        if re.search(rf'Ciphers.*{cipher}', cfg):
            print(f"Weak cipher found in sshd_config: {cipher}")
    for mac in WEAK_MACS:
        if re.search(rf'MACs.*{mac}', cfg):
            print(f"Weak MAC found in sshd_config: {mac}")

if __name__ == "__main__":
    main()