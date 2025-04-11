from PIL import Image
import os
import asyncio
from concurrent.futures import ProcessPoolExecutor

def resize_image(filename, width, height):
    img = Image.open(filename)
    img = img.resize((width, height))
    img.save(f"resized_{filename}")
    return f"Resized {filename}"

async def resize_images(folder_path, width, height):
    with ProcessPoolExecutor() as executor:
        loop = asyncio.get_event_loop()
        tasks = []
        for filename in os.listdir(folder_path):
            if filename.endswith('.jpg'):
                tasks.append(loop.run_in_executor(
                    executor, resize_image, os.path.join(folder_path, filename), width, height))
        results = await asyncio.gather(*tasks)
        print(results)

folder = '/path/to/your/images'
asyncio.run(resize_images(folder, 800, 600))
