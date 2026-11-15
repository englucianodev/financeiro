import type { NextConfig } from "next";
const nextConfig: NextConfig = {
  outputFileTracingIncludes: {'/api/statements/unlock':['./node_modules/pdfjs-dist/legacy/build/pdf.worker.mjs','./node_modules/pdfjs-dist/standard_fonts/**/*']},
  serverExternalPackages: ['@napi-rs/canvas','pdfjs-dist'],
  allowedDevOrigins: ["127.0.0.1"],
  // APK do app Android: o celular reconhece como instalador e baixa como arquivo.
  async headers() {
    return [{ source: '/download/:file*.apk', headers: [
      { key: 'Content-Type', value: 'application/vnd.android.package-archive' },
      { key: 'Content-Disposition', value: 'attachment; filename="Duo-Android.apk"' },
      { key: 'Cache-Control', value: 'public, max-age=0, must-revalidate' },
    ] }];
  },
};
export default nextConfig;
