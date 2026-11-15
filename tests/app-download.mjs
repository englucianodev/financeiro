import assert from 'node:assert/strict';
import {isAndroidBrowser,isBannerDismissed,APK_PATH} from '../.test-build/app-download.js';

const chromeAndroid='Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36';
const samsungInternet='Mozilla/5.0 (Linux; Android 13; SAMSUNG SM-A546E) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/121.0.0.0 Mobile Safari/537.36';
const duoWebView='Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/129.0.0.0 Mobile Safari/537.36';
const iphone='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const windows='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';

assert.equal(isAndroidBrowser(chromeAndroid),true,'Chrome no Android mostra o aviso');
assert.equal(isAndroidBrowser(samsungInternet),true,'Samsung Internet mostra o aviso');
assert.equal(isAndroidBrowser(duoWebView),false,'Dentro do próprio app (WebView) não mostra');
assert.equal(isAndroidBrowser(iphone),false,'iPhone não instala APK');
assert.equal(isAndroidBrowser(windows),false,'Computador não mostra');
assert.equal(isAndroidBrowser(''),false);

const day=86_400_000,now=Date.UTC(2026,10,15);
assert.equal(isBannerDismissed(null,now),false,'Nunca fechado');
assert.equal(isBannerDismissed(String(now-5*day),now),true,'Fechado há 5 dias continua escondido');
assert.equal(isBannerDismissed(String(now-31*day),now),false,'Volta depois de 30 dias');
assert.equal(isBannerDismissed('lixo',now),false,'Valor inválido é ignorado');
assert.equal(isBannerDismissed(String(now+day),now),false,'Data no futuro é ignorada');

assert.equal(APK_PATH,'/download/Duo-Android.apk');
console.log('Aviso do app Android: só navegador Android, fora do app, e pausa de 30 dias ao fechar OK');
