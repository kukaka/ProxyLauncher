// Read Chromium Simple Cache stream 1 using the stream 0 footer and key length.
// stream 1 may have a zero size field even when its body is nonempty.
// Usage: node tools/extract-douyin-cache.cjs [cache-directory] [output-directory]
// Reads the app cache only; writes decoded JavaScript to the output directory.
const fs=require('fs'),path=require('path'),z=require('zlib');
const dir=process.argv[2] || path.join(process.env.HOME,'Library/Application Support/抖音/Cache/Cache_Data');
const out=process.argv[3] || '/tmp/proxylauncher-douyin-js';fs.mkdirSync(out,{recursive:true});
const magic=Buffer.from('d8410d97456ffaf4','hex');let candidates=0,decoded=0,hits=[];
for(const name of fs.readdirSync(dir)){
 if(!name.endsWith('_0'))continue;
 let b;try{b=fs.readFileSync(path.join(dir,name))}catch{continue}
 if(b.length<48||b.readUInt32LE(0)!==0xa7725c30)continue;
 const keylen=b.readUInt32LE(12),start=24+keylen;
 if(start>b.length)continue;
 const key=b.subarray(24,start).toString();
 if(!key.includes('.js'))continue;
 candidates++;
 // The final footer describes stream 0 (HTTP metadata). A SHA-256 of
 // the key may precede it. Stream 1's footer is just before that metadata.
 const eof0=b.length-24;
 if(!b.subarray(eof0,eof0+8).equals(magic))continue;
 const flags=b.readUInt32LE(eof0+8);
 const metadataSize=Number(b.readBigUInt64LE(eof0+16));
 const eof1=eof0-((flags&2)?32:0)-metadataSize-24;
 if(eof1<start||!b.subarray(eof1,eof1+8).equals(magic))continue;
 const declaredBodySize=Number(b.readBigUInt64LE(eof1+16));
 if(declaredBodySize!==0&&declaredBodySize!==eof1-start)continue;
 const body=b.subarray(start,eof1);
 let result;
 for(const decode of [x=>z.brotliDecompressSync(x,{maxOutputLength:30000000}),x=>z.gunzipSync(x,{maxOutputLength:30000000}),x=>z.inflateSync(x,{maxOutputLength:30000000}),x=>x]){
  try{const v=decode(body); if(v.includes(Buffer.from('function'))||v.includes(Buffer.from('webpackChunk'))){result=v;break}}catch{}
 }
 if(!result)continue;
 decoded++;fs.writeFileSync(path.join(out,name+'.js'),result);
 if(/38918\s*:/.test(result.toString()))hits.push(name);
}
console.log({candidates,decoded,hits});
