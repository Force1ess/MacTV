#!/usr/bin/env node
// Build the independent official repository; never vendor its source into MacTV.
import {spawnSync} from 'node:child_process';
import {existsSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const mode=process.argv[2];
if (!['build','test','path'].includes(mode)) throw Error('Use build, test, or path');
const source=JSON.parse(readFileSync(join(root,'config/plugin-sources.json'),'utf8')).defaultSources.find(x=>x.id==='org.mactv.official');
if (!source || source.reference!=='main') throw Error('The official source must declare main');
const override=process.env.MACTV_PLUGINS_DIR;
const checkout=resolve(override || join(root,'.build/plugin-sources/official'));
function git(args, capture=false) {
  const result=spawnSync('git',args,{cwd:root,encoding:'utf8',stdio:capture ? ['ignore','pipe','inherit']:'inherit'});
  if(result.error) throw result.error;
  if(result.status!==0) throw Error('Plugin source Git command failed');
  return result.stdout?.trim();
}
if (!existsSync(join(checkout,'.git'))) {
  if(override) throw Error('MACTV_PLUGINS_DIR must point to a Git checkout');
  mkdirSync(dirname(checkout),{recursive:true});
  git(['clone','--branch',source.reference,'--single-branch','--',source.repository,checkout]);
} else if (!override && mode!=='path') {
  if(git(['-C',checkout,'remote','get-url','origin'],true)!==source.repository) throw Error('Unexpected plugin cache origin');
  if(git(['-C',checkout,'status','--porcelain','--untracked-files=normal'],true)) throw Error('Plugin cache has local changes; use MACTV_PLUGINS_DIR for development');
  git(['-C',checkout,'fetch','origin',source.reference]);
  git(['-C',checkout,'checkout',source.reference]);
  git(['-C',checkout,'merge','--ff-only','origin/'+source.reference]);
}
if(mode==='path') {
  process.stdout.write(checkout+'\n');
} else {
  const revision=git(['-C',checkout,'rev-parse','HEAD'],true);
  const result=spawnSync(process.execPath,[join(checkout,'tools/plugins/example-packages.mjs'),mode],{cwd:checkout,stdio:'inherit'});
  if(result.error) throw result.error;
  if(result.status!==0) throw Error('Independent plugin package command failed');
  if(mode==='build') {
    mkdirSync(join(root,'dist'),{recursive:true});
    writeFileSync(join(root,'dist/plugin-source.json'),JSON.stringify({repository:source.repository,reference:source.reference,revision},null,2)+'\n');
  }
}
