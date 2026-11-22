// Starts a Profile through AnyBrowser's automation API and drives it with Playwright.
//
//   npm install playwright
//   ANYBROWSER_TOKEN=<访问令牌> node playwright.mjs <Profile id>
import { chromium } from 'playwright';

const api = `http://127.0.0.1:${process.env.ANYBROWSER_PORT ?? 50330}/api/v1`;
const headers = { Authorization: `Bearer ${process.env.ANYBROWSER_TOKEN}` };

const started = await (await fetch(`${api}/profiles/${process.argv[2]}/start`, { method: 'POST', headers })).json();
if (started.error) throw new Error(started.error.message);

const browser = await chromium.connectOverCDP(started.debug.http);
// The Profile's own context, with its cookies and logins. browser.newContext() would start empty.
const context = browser.contexts()[0];
const page = await context.newPage();
await page.goto('https://example.com/');
console.log(await page.title());
await page.close();
// Only disconnects: the Profile keeps running until it is stopped.
await browser.close();
