// Aviso de download do app Android (APK servido pelo próprio site em /public/download).
export const APK_PATH='/download/Duo-Android.apk';
export const APP_PAGE_PATH='/android';
export const APP_VERSION='1.0.0';
export const BANNER_DISMISS_KEY='duo:app-android-banner-dismissed-at';
const DISMISS_DAYS=30;
const DAY_MS=86_400_000;

/** Navegador Android comum. O WebView do próprio app Duo marca o user agent com "; wv)" e fica de fora. */
export function isAndroidBrowser(userAgent:string):boolean{
  return /Android/i.test(userAgent)&&!/;\s*wv\)/i.test(userAgent);
}

/** Se a pessoa fechou o aviso há menos de 30 dias. Valores inválidos ou no futuro são ignorados. */
export function isBannerDismissed(storedAt:string|null,now:number):boolean{
  if(!storedAt)return false;
  const at=Number(storedAt);
  if(!Number.isFinite(at)||at<=0||at>now)return false;
  return now-at<DISMISS_DAYS*DAY_MS;
}
