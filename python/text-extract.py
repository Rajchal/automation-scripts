from PIL import Image
import pytesseract

def extract_text_from_image(image_path):
    # Open the image file
    img = Image.open(image_path)
    
    # Use pytesseract to extract text
    text = pytesseract.image_to_string(img)
    
    return text

image_path = 'path_to_your_image.jpg'
extracted_text = extract_text_from_image(image_path)
print("Extracted Text:\n", extracted_text)
