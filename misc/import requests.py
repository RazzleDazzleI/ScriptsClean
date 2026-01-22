from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
import requests
import os

# Setup WebDriver (Ensure chromedriver is installed)
service = Service("chromedriver.exe")  # Change to your path
driver = webdriver.Chrome(service=service)

# Open the target webpage
url = "https://huskies.loopcommunications.com/ucp/"
driver.get(url)

# Create folder to save files
download_folder = "downloaded_files"
os.makedirs(download_folder, exist_ok=True)

# Find all links
links = driver.find_elements(By.TAG_NAME, "a")
for link in links:
    file_url = link.get_attribute("href")
    
    if file_url and (".js" in file_url or ".css" in file_url or ".png" in file_url or ".woff" in file_url):
        file_name = os.path.join(download_folder, os.path.basename(file_url))
        
        response = requests.get(file_url)
        if response.status_code == 200:
            with open(file_name, "wb") as file:
                file.write(response.content)
            print(f"Downloaded: {file_name}")

# Close browser
driver.quit()
