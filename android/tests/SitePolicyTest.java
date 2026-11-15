import br.net.luciano.duo.SitePolicy;
public final class SitePolicyTest {
    public static void main(String[] args) {
        SitePolicy policy = new SitePolicy("www.luciano.net.br");
        String[] allowed = {"https://www.luciano.net.br/", "https://luciano.net.br/redefinir-senha?code=abc", "https://WWW.LUCIANO.NET.BR:443/"};
        String[] denied = {"http://www.luciano.net.br/", "https://www.luciano.net.br.evil.test/", "https://evil.test/?site=www.luciano.net.br", "https://user@www.luciano.net.br/", "https://www.luciano.net.br:9443/", "javascript:alert(1)", "file:///sdcard/a.pdf", "content://documents/a", "intent://x", "https://127.0.0.1/", "https://www.luciano.net.br./", "not a URL"};
        for(String value:allowed) if(!policy.allows(value)) throw new AssertionError("Rejected trusted origin: "+value);
        for(String value:denied) if(policy.allows(value)) throw new AssertionError("Accepted unsafe origin: "+value);
        if(policy.allows(null)) throw new AssertionError("Accepted null");
        if(!SitePolicy.safeFilename("../../secret.txt").equals("despesas.txt")) throw new AssertionError("Unsafe filename");
        if(!SitePolicy.safeFilename("despesas-2026-11.txt").equals("despesas-2026-11.txt")) throw new AssertionError("Changed valid filename");
        if(SitePolicy.safeFilename("a".repeat(200)).length()!=100) throw new AssertionError("Filename limit");
        System.out.println("Android: HTTPS/origins, www alias, redirects, unsafe protocols, credentials, port and export filenames OK");
    }
}
