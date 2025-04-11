import aiohttp
import asyncio
from bs4 import BeautifulSoup

async def fetch(session, url):
    async with session.get(url) as response:
        return await response.text()

async def scrape(urls):
    async with aiohttp.ClientSession() as session:
        tasks = [fetch(session, url) for url in urls]
        html_pages = await asyncio.gather(*tasks)
        for html in html_pages:
            soup = BeautifulSoup(html, 'html.parser')
            print(soup.title.string)

urls = ['https://example.com/page1', 'https://example.com/page2'] asyncio.run(scrape(urls))
