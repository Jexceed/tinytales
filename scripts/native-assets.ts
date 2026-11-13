import { Resvg } from '@resvg/resvg-js';
import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

await mkdir('macos/Resources/Scenes', { recursive: true });
for (const id of ['rain','moon','seed']) {
  await copyFile(`public/scenes/${id}.png`,`macos/Resources/Scenes/${id}.png`);
  const svg=await readFile(`public/scenes/${id}.svg`,'utf8');
  await writeFile(`macos/Resources/Scenes/${id}-vision.png`,new Resvg(svg,{fitTo:{mode:'width',value:512}}).render().asPng());
}
await mkdir('build/TinyTales.iconset',{recursive:true});
const result=spawnSync('xcrun',['swift','scripts/export-pet-assets.swift'],{stdio:'inherit'});
if(result.status!==0)process.exit(result.status||1);
for(const size of [16,32,128,256,512])for(const pixelScale of [1,2]){
  const name=`icon_${size}x${size}${pixelScale===2?'@2x':''}.png`;
  const png=await readFile(`build/TinyTales.iconset/${name}`);
  const expected=size*pixelScale;
  if(png.readUInt32BE(16)!==expected||png.readUInt32BE(20)!==expected){
    throw new Error(`Invalid icon dimensions for ${name}; refusing to package stale Retina resources.`);
  }
}
const worlds=spawnSync('xcrun',['swift','scripts/export-story-worlds.swift'],{stdio:'inherit'});
if(worlds.status!==0)process.exit(worlds.status||1);
console.log('Prepared native scenes and the rainbow-unicorn storybook brand icon.');
