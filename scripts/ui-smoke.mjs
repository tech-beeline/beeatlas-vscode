#!/usr/bin/env node
// UI-смоук code-server в реальном браузере: логин через форму, работающий workbench,
// установленное C4-расширение в панели Extensions, активация расширения на .dsl файле.
//
// Переменные:
//   PASSWORD          — обязательна
//   BASE_URL          — по умолчанию http://127.0.0.1:8088
//   CDP_URL           — подключиться к уже запущенному Chrome (например http://127.0.0.1:9222)
//   CHROME_PATH       — путь к Chrome/Chromium, если CDP_URL не задан
//   SMOKE_FILE        — имя файла в workspace для проверки активации (по умолчанию smoke.dsl)
//   SCREENSHOT_DIR    — куда складывать скриншоты (по умолчанию ./logs)
import fs from 'node:fs';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const BASE_URL = process.env.BASE_URL || 'http://127.0.0.1:8088';
const PASSWORD = process.env.PASSWORD;
const SMOKE_FILE = process.env.SMOKE_FILE || 'smoke.dsl';
const SCREENSHOT_DIR = process.env.SCREENSHOT_DIR || 'logs';
const WORKBENCH_TIMEOUT = Number(process.env.WORKBENCH_TIMEOUT || 120000);

if (!PASSWORD) {
    console.error('PASSWORD is required');
    process.exit(1);
}

const CHROME_CANDIDATES = [
    process.env.CHROME_PATH,
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
    '/opt/google/chrome/chrome',
].filter(Boolean);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findChrome() {
    for (const candidate of CHROME_CANDIDATES) {
        if (fs.existsSync(candidate)) return candidate;
    }
    return null;
}

async function connect() {
    if (process.env.CDP_URL) {
        return puppeteer.connect({ browserURL: process.env.CDP_URL, defaultViewport: { width: 1600, height: 1000 } });
    }
    const executablePath = findChrome();
    if (!executablePath) {
        throw new Error('Chrome/Chromium не найден. Задайте CHROME_PATH или CDP_URL.');
    }
    return puppeteer.launch({
        executablePath,
        headless: true,
        defaultViewport: { width: 1600, height: 1000 },
        args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
    });
}

const results = [];
function pass(message) {
    results.push(`  ok   ${message}`);
    console.log(`  ok   ${message}`);
}
function fail(message) {
    results.push(`  FAIL ${message}`);
    console.error(`  FAIL ${message}`);
    throw new Error(message);
}

fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

const browser = await connect();
const context = await browser.createBrowserContext();
const page = await context.newPage();
let exiting = false;

try {
    console.log(`== UI-смоук: ${BASE_URL}`);

    // 1. Страница логина.
    const response = await page.goto(`${BASE_URL}/login`, { waitUntil: 'domcontentloaded', timeout: WORKBENCH_TIMEOUT });
    if (!response || response.status() !== 200) fail(`/login вернул ${response && response.status()}`);
    await page.waitForSelector('input[name=password]', { timeout: 30000 });
    pass('страница логина открылась');

    // 2. Логин через форму.
    await page.type('input[name=password]', PASSWORD);
    await page.click('input[type=submit]');
    await page.waitForSelector('.monaco-workbench', { timeout: WORKBENCH_TIMEOUT });
    pass('вход по паролю, workbench загрузился');

    // 3. Расширение видно в панели Extensions.
    await page.click('.activitybar .codicon-extensions-view-icon');
    await page.waitForFunction(
        () => document.body.innerText.includes('C4 Architecture As A Code'),
        { timeout: 60000 },
    );
    pass('расширение видно в панели Extensions');
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'extensions-view.png') });

    // 4. Активация расширения: открываем .dsl файл, язык должен определиться как C4.
    await page.keyboard.down('Control');
    await page.keyboard.press('KeyP');
    await page.keyboard.up('Control');
    await sleep(1500);
    await page.keyboard.type(SMOKE_FILE);
    await sleep(1500);
    await page.keyboard.press('Enter');
    await page.waitForFunction(
        () => [...document.querySelectorAll('.statusbar .statusbar-item')].some((e) => (e.innerText || '').trim() === 'C4'),
        { timeout: 60000 },
    );
    pass(`${SMOKE_FILE} открыт, язык определён как C4`);
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'dsl-open.png') });

    // 5. Команды расширения зарегистрированы (расширение реально активировалось).
    await page.keyboard.down('Control');
    await page.keyboard.down('Shift');
    await page.keyboard.press('KeyP');
    await page.keyboard.up('Shift');
    await page.keyboard.up('Control');
    await sleep(1500);
    await page.keyboard.type('diagram preview');
    await page.waitForFunction(
        () => /diagram preview/i.test(document.body.innerText),
        { timeout: 30000 },
    );
    pass('команды расширения доступны в палитре команд');
    await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'palette.png') });

    console.log('== UI-смоук пройден');
} catch (error) {
    try {
        await page.screenshot({ path: path.join(SCREENSHOT_DIR, 'failure.png') });
    } catch {
        // скриншот не критичен
    }
    console.error(`\nUI-смоук упал: ${error.message}`);
    exiting = true;
    process.exitCode = 1;
} finally {
    await context.close().catch(() => {});
    if (process.env.CDP_URL) {
        await browser.disconnect();
    } else {
        await browser.close().catch(() => {});
    }
    if (!exiting) process.exitCode = 0;
}
