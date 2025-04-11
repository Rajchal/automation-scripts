import aiohttp
import asyncio
import aiofiles

async def download_file(url, filename):
    async with aiohttp.ClientSession() as session:
        async with session.get(url) as response:
            async with aiofiles.open(filename, 'wb') as file:
                await file.write(await response.read())
            print(f"Downloaded {filename}")

urls = {
    'https://example.com/file1.zip': 'file1.zip',
    'https://example.com/file2.zip': 'file2.zip'
}

async def download_all():
    tasks = [download_file(url, filename) for url, filename in urls.items()]
    await asyncio.gather(*tasks)

asyncio.run(download_all())
