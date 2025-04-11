import random
import asyncio
import string

async def generate_password(length=12):
    characters = string.ascii_letters + string.digits + string.punctuation
    password = ''.join(random.choice(characters) for _ in range(length))
    return password

async def generate_multiple_passwords(n, length=12):
    tasks = [generate_password(length) for _ in range(n)]
    passwords = await asyncio.gather(*tasks)
    print(passwords)

asyncio.run(generate_multiple_passwords(5))
