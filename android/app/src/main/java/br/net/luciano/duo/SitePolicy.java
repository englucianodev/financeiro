package br.net.luciano.duo;

import java.net.URI;
import java.util.Locale;

/** No wildcards: only the configured HTTPS site and its www alias stay inside the app. */
public final class SitePolicy {
    private final String host;
    private final String alias;
    public SitePolicy(String host) {
        this.host = host.toLowerCase(Locale.ROOT);
        alias = this.host.startsWith("www.") ? this.host.substring(4) : "www." + this.host;
    }
    public boolean allows(String value) {
        try {
            URI uri = new URI(value);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getRawUserInfo() != null) return false;
            String candidate = uri.getHost();
            return candidate != null && (host.equalsIgnoreCase(candidate) || alias.equalsIgnoreCase(candidate))
                    && (uri.getPort() == -1 || uri.getPort() == 443);
        } catch (Exception ignored) { return false; }
    }
    public static String safeFilename(String name) {
        String cleaned = name == null ? "despesas.txt" : name.replaceAll("[^a-zA-Z0-9._-]", "_");
        if (cleaned.isEmpty() || cleaned.startsWith(".")) cleaned = "despesas.txt";
        return cleaned.substring(0, Math.min(100, cleaned.length()));
    }
}
