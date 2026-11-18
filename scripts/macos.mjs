import { spawnSync } from 'node:child_process';
import { mkdirSync, readdirSync, copyFileSync, cpSync, existsSync, utimesSync } from 'node:fs';
import { resolve, join } from 'node:path';

const command=process.argv[2]||'build';
const root=resolve(import.meta.dirname,'..');
const app=join(root,'build/macos/小小故事屋.app');
function run(cmd,args){const r=spawnSync(cmd,args,{cwd:root,stdio:'inherit'});if(r.status!==0)process.exit(r.status||1);}
if(!['build','install','test','live','tts-test','phone-test','phone-live','greeting-live','story-live','experience-live','content-eval'].includes(command))throw new Error('Unknown macOS command.');
run('python3',[join(root,'scripts/check-specs.py')]);
mkdirSync(join(root,'build/native'),{recursive:true});
const core=['ContentLibrary.swift','ClassicalKnowledge.swift','ContentQuality.swift','Models.swift','ConversationLabels.swift','LocalStore.swift','Credentials.swift','ResponseStream.swift','VoiceStyle.swift','VoiceIntent.swift','SpeechRecognition.swift','OpenAIClient.swift','CompanionEngine.swift','StoryArtwork.swift','PartnerTools.swift','LocalTTS.swift','TeacherSpeech.swift','PetSprites.swift','PetBehavior.swift','RealtimeWire.swift','VoiceTurns.swift','VoiceTurnPolicy.swift','RealtimeNarrator.swift','CallAudio.swift','RealtimeCall.swift','NativeVoice.swift','AppModel.swift'].map(f=>join(root,'macos/Sources',f));
const flags=['-swift-version','5','-target','arm64-apple-macosx14.0','-framework','AppKit','-framework','SwiftUI','-framework','AVFoundation','-framework','Security','-lsqlite3'];
if(['test','live','tts-test','phone-test','phone-live','greeting-live','story-live','experience-live','content-eval'].includes(command)){
  const phone=command.startsWith('phone-');
  const evaluation=command==='content-eval';
  const target=join(root,`build/native/${evaluation?'ContentEvals':phone?'PhoneTests':'NativeTests'}`);
  if(phone){
    const scenes=join(root,'macos/Resources/Scenes');
    cpSync(scenes,join(root,'build/native/Scenes'),{recursive:true,filter:path=>path===scenes||path.endsWith('-vision.png')});
  }
  const extraTests=phone?['VoiceTurnTests.swift','TeacherSpeechTests.swift','NaturalTurnTests.swift','NaturalTurnLive.swift','DuplexLive.swift','VoiceLiveTests.swift','VoiceReliabilityTests.swift','VoiceReliabilityLive.swift','ArtworkPhoneLive.swift','SoftVoiceLive.swift','ClassicalKnowledgePhoneTests.swift','ConversationLabelsPhoneTests.swift','BackgroundConversationFixtures.swift','BackgroundConversationPhoneTests.swift','ConversationToolPhoneTests.swift']:evaluation?[]:['TeacherVoiceEvals.swift','PetBehaviorTests.swift','ArtworkTests.swift','ArtworkLive.swift','ConversationDeletionTests.swift','ConversationLabelsTests.swift','BackgroundConversationFixtures.swift','BackgroundConversationTests.swift','ClassicalKnowledgeTests.swift','ConversationToolTests.swift'];
  run('xcrun',['swiftc',...flags,...core,join(root,`macos/Tests/${evaluation?'ContentEvals':phone?'PhoneTests':'NativeTests'}.swift`),...extraTests.map(f=>join(root,'macos/Tests',f)),'-o',target]);
  run(target,evaluation?process.argv.slice(3):command==='live'||command==='phone-live'?['--live']:command==='tts-test'?['--tts-local']:command==='greeting-live'?['--greeting-live']:command==='story-live'?['--story-live']:command==='experience-live'?['--experience-live']:[]);
}else{
  run(process.execPath,['--import','tsx','scripts/native-assets.ts']);
  mkdirSync(join(app,'Contents/MacOS'),{recursive:true});mkdirSync(join(app,'Contents/Resources'),{recursive:true});
  const sources=readdirSync(join(root,'macos/Sources')).filter(f=>f.endsWith('.swift')).map(f=>join(root,'macos/Sources',f));
  run('xcrun',['swiftc','-O',...flags,...sources,'-o',join(app,'Contents/MacOS/TinyTales')]);
  copyFileSync(join(root,'macos/Info.plist'),join(app,'Contents/Info.plist'));
  cpSync(join(root,'macos/Resources'),join(app,'Contents/Resources'),{recursive:true});
  run('iconutil',['-c','icns',join(root,'build/TinyTales.iconset'),'-o',join(app,'Contents/Resources/TinyTales.icns')]);
  run('python3',[join(root,'scripts/sign-macos.py'),app]);
  run('codesign',['--verify','--deep','--strict',app]);
  console.log(`Built: ${app}`);
  if(command==='install'){
    run('python3',[join(root,'scripts/install-qwen-tts.py')]);
    run('python3',[join(root,'scripts/install-runtime-resources.py')]);
    const installed='/Applications/小小故事屋.app';
    if(existsSync(installed)){
      const backupDirectory=join(root,'build/install-backups.noindex');mkdirSync(backupDirectory,{recursive:true});
      const backup=join(backupDirectory,`小小故事屋-${new Date().toISOString().replace(/[:.]/g,'-')}.app`);
      run('ditto',[installed,backup]);console.log(`Previous app preserved: ${backup}`);
    }
    // Keep the installed bundle's directory identity so existing shortcuts do not
    // follow a renamed old app into a backup directory.
    run('ditto',[app,installed]);
    const now=new Date();utimesSync(installed,now,now);
    run('codesign',['--verify','--deep','--strict',installed]);
    run('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',['-f',installed]);
    console.log(`Installed and registered: ${installed}`);
  }
}
