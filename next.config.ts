import type { NextConfig } from "next";
const nextConfig: NextConfig = { outputFileTracingIncludes: {'/api/statements/unlock':['./node_modules/pdfjs-dist/legacy/build/pdf.worker.mjs','./node_modules/pdfjs-dist/standard_fonts/**/*']}, serverExternalPackages: ['@napi-rs/canvas','pdfjs-dist'], allowedDevOrigins: ["127.0.0.1"] };
export default nextConfig;
