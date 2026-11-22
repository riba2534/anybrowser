// Starts a Profile through AnyBrowser's automation API and drives it with Puppeteer.
//
//   npm install puppeteer-core
//   ANYBROWSER_TOKEN=<访问令牌> node puppeteer.mjs <Profile id>
import puppeteer from 'puppeteer-core';

const api = `http://127.0.0.1:${process.env.ANYBROWSER_PORT ?? 50330}/api/v1`;
const headers = { Authorization: `Bearer ${process.env.ANYBROWSER_TOKEN}` };

const started = await (await fetch(`${api}/profiles/${process.argv[2]}/start`, { method: 'POST', headers })).json();
if (started.error) throw new Error(started.error.message);

// defaultViewport: null keeps the window's own size instead of emulating an 800×600 screen.
const browser = await puppeteer.connect({ browserWSEndpoint: started.debug.webSocket, defaultViewport: null });
const page = await browser.newPage();
await page.goto('https://example.com/');
console.log(await page.title());
await page.close();
// Only disconnects: the Profile keeps running until it is stopped.
await browser.disconnect();
