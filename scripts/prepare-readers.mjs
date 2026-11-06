import {gunzipSync} from 'node:zlib';
import {readFile,writeFile} from 'node:fs/promises';
import {mkdir,cp,copyFile} from 'node:fs/promises';
await mkdir('public/vendor/ocr',{recursive:true});
await copyFile('node_modules/pdfjs-dist/build/pdf.worker.min.mjs','public/vendor/pdf.worker.min.mjs');
await copyFile('node_modules/tesseract.js-core/tesseract-core-lstm.wasm.js','public/vendor/ocr/tesseract-core-lstm.wasm.js');
await copyFile('node_modules/tesseract.js-core/tesseract-core-lstm.wasm','public/vendor/ocr/tesseract-core-lstm.wasm');
await copyFile('node_modules/tesseract.js/dist/worker.min.js','public/vendor/ocr/worker.min.js');


await writeFile('public/vendor/ocr/por.traineddata',gunzipSync(await readFile('node_modules/@tesseract.js-data/por/4.0.0/por.traineddata.gz')));
