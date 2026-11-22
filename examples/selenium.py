# Starts a Profile through AnyBrowser's automation API and drives it with Selenium.
#
#   pip install selenium
#   npx @puppeteer/browsers install chromedriver@148    # the built-in engine is Chromium 148
#   ANYBROWSER_TOKEN=<访问令牌> CHROMEDRIVER=<chromedriver 路径> python3 selenium.py <Profile id>
import json
import os
import sys
import urllib.request

from selenium import webdriver
from selenium.webdriver.chrome.service import Service

port = os.environ.get("ANYBROWSER_PORT", "50330")
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/v1/profiles/{sys.argv[1]}/start",
    method="POST",
    headers={"Authorization": f"Bearer {os.environ['ANYBROWSER_TOKEN']}"},
)
# No proxy for 127.0.0.1, whatever the system settings say.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
started = json.load(opener.open(request))

options = webdriver.ChromeOptions()
options.debugger_address = started["debug"]["http"].removeprefix("http://")
driver = webdriver.Chrome(service=Service(os.environ["CHROMEDRIVER"]), options=options)
driver.get("https://example.com/")
print(driver.title)
# Ends chromedriver only: a browser attached through debuggerAddress keeps running.
driver.quit()
