import {build} from 'esbuild';
import {readFileSync,writeFileSync,copyFileSync,readdirSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
const out=resolve('../Shared/Resources');
await build({entryPoints:['mermaid-entry.js'],bundle:true,format:'iife',target:'safari17',minify:true,legalComments:'eof',outfile:out+'/mermaid.min.js'});
copyFileSync('node_modules/katex/dist/katex.min.js',out+'/katex.min.js');
const lock=JSON.parse(readFileSync('package-lock.json'));
let notices='Margined offline rendering dependencies. Generated from Rendering/package-lock.json.\n';
for(const [path,info] of Object.entries(lock.packages).sort()) {
 if(!path)continue;
 const name=info.name??path.split('node_modules/').at(-1);
 notices+='\n\n=== '+name+' '+info.version+' ('+(info.license??'see notice')+') ===\n';
 if(!existsSync(path))continue;
 for(const file of readdirSync(path).filter(n=>/^(license|copying|notice)(\.|$|-)/i.test(n))) {
  try{notices+=readFileSync(path+'/'+file,'utf8')+'\n';}catch{}
 }
}
writeFileSync(out+'/Renderer-LICENSES.txt',notices);
