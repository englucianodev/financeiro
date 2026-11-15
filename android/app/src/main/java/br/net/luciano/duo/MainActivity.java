package br.net.luciano.duo;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.webkit.CookieManager;
import android.webkit.JsResult;
import android.webkit.SslErrorHandler;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebMessage;
import android.webkit.WebMessagePort;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import org.json.JSONObject;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/** The published app owns Auth and all finance logic. There is no second financial database. */
public final class MainActivity extends Activity {
    private static final int PICK_FILE = 11;
    private static final int SAVE_TEXT = 12;
    private static final int MAX_TEXT = 256 * 1024;
    private WebView web;
    private ProgressBar progress;
    private LinearLayout errorPanel;
    private TextView errorMessage;
    private SitePolicy policy;
    private String site;
    private WebMessagePort nativePort;
    private ValueCallback<Uri[]> fileCallback;
    private String pendingText;
    private boolean mainFrameFailed;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        site = getString(R.string.site_url);
        policy = new SitePolicy(getString(R.string.site_host));
        if (!policy.allows(site)) throw new IllegalStateException("O endereço do aplicativo deve usar HTTPS.");
        buildLayout();
        configureWebView();
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::goBack);
        }
        if (saved != null) pendingText = saved.getString("pendingText");
        if (saved == null || web.restoreState(saved) == null || !policy.allows(web.getUrl())) web.loadUrl(site);
    }

    private void buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(61, 32, 60));
        LinearLayout toolbar = new LinearLayout(this);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        TextView title = new TextView(this);
        title.setGravity(Gravity.CENTER_VERTICAL);
        title.setText("Duo"); title.setTextSize(20); title.setTextColor(Color.WHITE);
        title.setPadding(dp(16), 0, 0, 0);
        toolbar.addView(title, new LinearLayout.LayoutParams(0, dp(52), 1));
        Button reload = new Button(this);
        reload.setText("↻"); reload.setTextSize(24);
        reload.setContentDescription("Atualizar dados do site");
        reload.setOnClickListener(v -> retry());
        toolbar.addView(reload, new LinearLayout.LayoutParams(dp(56), dp(52)));
        Button browser = new Button(this);
        browser.setText("↗"); browser.setTextSize(22);
        browser.setContentDescription("Abrir site no navegador");
        browser.setOnClickListener(v -> openExternal(Uri.parse(policy.allows(web.getUrl()) ? web.getUrl() : site)));
        toolbar.addView(browser, new LinearLayout.LayoutParams(dp(56), dp(52)));
        root.addView(toolbar);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        root.addView(progress, new LinearLayout.LayoutParams(-1, dp(3)));
        FrameLayout content = new FrameLayout(this);
        web = new WebView(this);
        web.setBackgroundColor(Color.WHITE);
        content.addView(web, new FrameLayout.LayoutParams(-1, -1));
        errorPanel = new LinearLayout(this);
        errorPanel.setOrientation(LinearLayout.VERTICAL);
        errorPanel.setGravity(Gravity.CENTER);
        errorPanel.setPadding(dp(24), dp(24), dp(24), dp(24));
        errorPanel.setBackgroundColor(Color.WHITE);
        errorMessage = new TextView(this);
        errorMessage.setTextColor(Color.rgb(61, 32, 60));
        errorMessage.setTextSize(18); errorMessage.setGravity(Gravity.CENTER);
        errorPanel.addView(errorMessage);
        Button retry = new Button(this);
        retry.setText("Tentar novamente"); retry.setOnClickListener(v -> retry());
        errorPanel.addView(retry);
        content.addView(errorPanel, new FrameLayout.LayoutParams(-1, -1));
        errorPanel.setVisibility(View.GONE);
        root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener((v, insets) -> {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                android.graphics.Insets ime = insets.getInsets(WindowInsets.Type.ime());
                v.setPadding(bars.left, bars.top, bars.right, Math.max(bars.bottom, ime.bottom));
                return WindowInsets.CONSUMED;
            });
        } else root.setFitsSystemWindows(true);
        setContentView(root);
    }

    private void configureWebView() {
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(true); // Only documents explicitly selected through Android's picker.
        settings.setAllowFileAccessFromFileURLs(false);
        settings.setAllowUniversalAccessFromFileURLs(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSafeBrowsingEnabled(true);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        settings.setMediaPlaybackRequiresUserGesture(true);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                if (!request.isForMainFrame()) return false;
                Uri uri = request.getUrl();
                if (policy.allows(uri.toString())) return false;
                openExternal(uri); return true;
            }
            @Override public void onPageStarted(WebView view, String url, android.graphics.Bitmap icon) {
                closeChannel(); mainFrameFailed = false; progress.setVisibility(View.VISIBLE);
            }
            @Override public void onPageFinished(WebView view, String url) {
                progress.setVisibility(View.GONE);
                CookieManager.getInstance().flush();
                if (!mainFrameFailed && policy.allows(url)) {
                    errorPanel.setVisibility(View.GONE);
                    connectPage(url);
                }
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) showError("Não foi possível acessar o Duo. Confira sua conexão e tente novamente. Seus dados permanecem no site.");
            }
            @Override public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame() && response.getStatusCode() >= 400) showError("O site está temporariamente indisponível (" + response.getStatusCode() + "). Tente novamente.");
            }
            @Override public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                handler.cancel(); showError("Não foi possível validar o certificado HTTPS do site. A conexão foi bloqueada.");
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onProgressChanged(WebView view, int value) { progress.setProgress(value); }
            @Override public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
                if (!policy.allows(url)) { result.cancel(); return true; }
                new AlertDialog.Builder(MainActivity.this).setTitle("Duo").setMessage(message)
                        .setPositiveButton("OK", (d, w) -> result.confirm()).setOnCancelListener(d -> result.cancel()).show();
                return true;
            }
            @Override public boolean onJsConfirm(WebView view, String url, String message, JsResult result) {
                if (!policy.allows(url)) { result.cancel(); return true; }
                new AlertDialog.Builder(MainActivity.this).setTitle("Confirmar no Duo").setMessage(message)
                        .setPositiveButton("Confirmar", (d, w) -> result.confirm())
                        .setNegativeButton("Cancelar", (d, w) -> result.cancel()).setOnCancelListener(d -> result.cancel()).show();
                return true;
            }
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (!policy.allows(view.getUrl())) { callback.onReceiveValue(null); return true; }
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                picker.addCategory(Intent.CATEGORY_OPENABLE);
                picker.setType("*/*");
                picker.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                try { startActivityForResult(picker, PICK_FILE); }
                catch (Exception error) { fileCallback.onReceiveValue(null); fileCallback = null; toast("Nenhum seletor de arquivos disponível."); }
                return true;
            }
        });
        web.setDownloadListener((url, userAgent, disposition, mime, length) -> {
            if (policy.allows(url)) openExternal(Uri.parse(url));
            else if (url.startsWith("blob:") && policy.allows(web.getUrl())) {
                web.evaluateJavascript("window.__duoSaveTextBlob&&window.__duoSaveTextBlob(" + JSONObject.quote(url) + ", 'despesas.txt');", null);
            } else toast("Download bloqueado: endereço não autorizado.");
        });
    }

    /** A message port is delivered only to the trusted top document, never a global JS interface. */
    private void connectPage(String loadedUrl) {
        closeChannel();
        String script = "(function(){if(window.__duoNativeInstalled)return;window.__duoNativeInstalled=true;"
                + "window.addEventListener('message',function(e){if(e.source!==null&&e.source!==window)return;if(e.origin&&e.origin!=='null'&&e.origin!==location.origin)return;if(e.data!=='duo-native-port'||!e.ports[0])return;"
                + "var port=e.ports[0];window.__duoNativePort=port;"
                + "var send=function(x){port.postMessage(JSON.stringify(x));};"
                + "try{Object.defineProperty(navigator,'share',{configurable:true,value:async function(d){send({type:'share',text:d.text||'',title:d.title||'Duo',url:d.url||''});}});}catch(e){}"
                + "try{var c=navigator.clipboard||{};Object.defineProperty(c,'writeText',{configurable:true,value:async function(t){send({type:'copy',text:String(t)});}});if(!navigator.clipboard)Object.defineProperty(navigator,'clipboard',{value:c});}catch(e){}"
                + "});var saveBlob=function(a){var url=a.href,name=a.download||'despesas.txt';"
                + "fetch(url).then(function(r){return r.blob();}).then(function(b){if(b.size>262144)throw Error('Arquivo muito grande');return b.text();})"
                + ".then(function(t){window.__duoNativePort.postMessage(JSON.stringify({type:'save',text:t,name:name}));})"
                + ".catch(function(){alert('Não foi possível baixar. Use Copiar ou Compartilhar.');});};"
                + "window.__duoSaveTextBlob=function(url,name){if(url.startsWith('blob:')&&window.__duoNativePort)saveBlob({href:url,download:name});};"
                + "var originalClick=HTMLAnchorElement.prototype.click;HTMLAnchorElement.prototype.click=function(){"
                + "if(this.hasAttribute('download')&&this.href.startsWith('blob:')&&window.__duoNativePort){saveBlob(this);return;}return originalClick.apply(this,arguments);};"
                + "document.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('a[download]');"
                + "if(!a||!a.href.startsWith('blob:')||!window.__duoNativePort)return;e.preventDefault();saveBlob(a);},true);})();";
        web.evaluateJavascript(script, ignored -> {
            if (mainFrameFailed || !policy.allows(web.getUrl())) return;
            Uri current = Uri.parse(web.getUrl());
            WebMessagePort[] channel = web.createWebMessageChannel();
            nativePort = channel[0];
            nativePort.setWebMessageCallback(new WebMessagePort.WebMessageCallback() {
                @Override public void onMessage(WebMessagePort port, WebMessage message) { handleMessage(message.getData()); }
            });
            Uri origin = new Uri.Builder().scheme("https").authority(current.getAuthority()).build();
            web.postWebMessage(new WebMessage("duo-native-port", new WebMessagePort[]{channel[1]}), origin);
        });
    }

    private void handleMessage(String raw) {
        if (!policy.allows(web.getUrl()) || raw == null || raw.length() > MAX_TEXT + 2048) return;
        try {
            JSONObject msg = new JSONObject(raw);
            String text = msg.optString("text");
            if (text.length() > MAX_TEXT) return;
            switch (msg.optString("type")) {
                case "copy":
                    ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Duo", text));
                    break;
                case "share":
                    String url = msg.optString("url");
                    if (!url.isEmpty() && !policy.allows(url)) return;
                    Intent share = new Intent(Intent.ACTION_SEND).setType("text/plain");
                    share.putExtra(Intent.EXTRA_TEXT, text + (url.isEmpty() ? "" : "\n" + url));
                    share.putExtra(Intent.EXTRA_SUBJECT, msg.optString("title", "Duo"));
                    startActivity(Intent.createChooser(share, "Compartilhar pelo Android"));
                    break;
                case "save":
                    if (pendingText != null) return;
                    pendingText = text;
                    Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("text/plain");
                    save.addCategory(Intent.CATEGORY_OPENABLE);
                    save.putExtra(Intent.EXTRA_TITLE, SitePolicy.safeFilename(msg.optString("name")));
                    try { startActivityForResult(save, SAVE_TEXT); }
                    catch (Exception error) { pendingText = null; toast("Não foi possível abrir o salvamento."); }
                    break;
                default: break;
            }
        } catch (Exception error) { toast("Não foi possível concluir esta ação."); }
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == PICK_FILE && fileCallback != null) {
            ArrayList<Uri> files = new ArrayList<>();
            if (result == RESULT_OK && data != null && policy.allows(web.getUrl())) {
                ClipData clips = data.getClipData();
                if (clips != null) for (int i = 0; i < Math.min(10, clips.getItemCount()); i++) addDocument(files, clips.getItemAt(i).getUri());
                else addDocument(files, data.getData());
            }
            fileCallback.onReceiveValue(files.isEmpty() ? null : files.toArray(new Uri[0]));
            fileCallback = null;
        } else if (request == SAVE_TEXT) {
            String text = pendingText; pendingText = null;
            Uri destination = data == null ? null : data.getData();
            if (result != RESULT_OK || text == null || destination == null || !"content".equals(destination.getScheme())) return;
            new Thread(() -> {
                try (OutputStream out = getContentResolver().openOutputStream(destination, "w")) {
                    if (out == null) throw new IllegalStateException("Destino indisponível");
                    out.write(text.getBytes(StandardCharsets.UTF_8));
                    runOnUiThread(() -> toast("Checklist salvo."));
                } catch (Exception error) { runOnUiThread(() -> toast("Não foi possível salvar o arquivo.")); }
            }, "duo-save").start();
        }
    }

    private static void addDocument(ArrayList<Uri> files, Uri uri) {
        if (uri != null && "content".equals(uri.getScheme())) files.add(uri);
    }
    private void openExternal(Uri uri) {
        String scheme = uri.getScheme();
        if (!"https".equalsIgnoreCase(scheme) && !"mailto".equalsIgnoreCase(scheme) && !"tel".equalsIgnoreCase(scheme)) return;
        try {
            String action = "tel".equalsIgnoreCase(scheme) ? Intent.ACTION_DIAL : "mailto".equalsIgnoreCase(scheme) ? Intent.ACTION_SENDTO : Intent.ACTION_VIEW;
            startActivity(new Intent(action, uri));
        } catch (Exception error) { toast("Nenhum aplicativo disponível para abrir o link."); }
    }
    private void retry() {
        errorPanel.setVisibility(View.GONE);
        String current = web.getUrl();
        if (policy.allows(current)) web.reload(); else web.loadUrl(site);
    }
    private void showError(String message) {
        mainFrameFailed = true; closeChannel(); progress.setVisibility(View.GONE);
        errorMessage.setText(message); errorPanel.setVisibility(View.VISIBLE);
    }
    private void closeChannel() { if (nativePort != null) { nativePort.close(); nativePort = null; } }
    private void goBack() {
        if (!policy.allows(web.getUrl())) { if (web.canGoBack()) web.goBack(); else finish(); return; }
        web.evaluateJavascript("(function(){var d=document.querySelector('dialog[open]');if(d){if(d.dispatchEvent(new Event('cancel',{cancelable:true})))d.close();return true;}if(document.querySelector('[role=dialog][aria-modal=true]')){document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return true;}return false;})()", handled -> {
            if (!"true".equals(handled) && !isFinishing()) { if (web.canGoBack()) web.goBack(); else finish(); }
        });
    }
    @Override public void onBackPressed() { goBack(); }
    @Override protected void onSaveInstanceState(Bundle state) {
        web.saveState(state);
        if (pendingText != null) state.putString("pendingText", pendingText);
        super.onSaveInstanceState(state);
    }
    @Override protected void onPause() { CookieManager.getInstance().flush(); web.onPause(); super.onPause(); }
    @Override protected void onResume() { super.onResume(); if (web != null) web.onResume(); }
    @Override protected void onDestroy() {
        if (fileCallback != null) fileCallback.onReceiveValue(null);
        closeChannel(); web.destroy(); super.onDestroy();
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private void toast(String message) { if (!isFinishing() && !isDestroyed()) Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }
}
