const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function invoke(name, action, input = {}, responses = [], sessionAvailable = false) {
  const requests = [];
  const requestOptions = [];
  const context = vm.createContext({host: {sessionAvailable, library(service, options = {}) {
    requests.push('native:' + service);
    requestOptions.push(JSON.parse(JSON.stringify(options)));
    assert.ok(responses.length, 'Unexpected native library request');
    return responses.shift();
  }, fetchJSON(url, options = {}) {
    requests.push(url);
    requestOptions.push(JSON.parse(JSON.stringify(options)));
    assert.ok(responses.length, 'Unexpected network request in fixture test');
    return responses.shift();
  }}});
  vm.runInContext(fs.readFileSync(path.join(__dirname, name === 'example' ? '../../src/Tests/Fixtures/example-plugin' : '../../src/integrations/' + name, 'plugin.js'), 'utf8'), context);
  context.request = {action, input};
  const result = vm.runInContext('JSON.stringify(plugin.handle(request.action, request.input))', context);
  return {result: JSON.parse(result), requests, requestOptions};
}

const checks = {};
const cloudPhotos = invoke('quark','browse',{media:'photos'},[{status:200,code:0,data:{list:[
 {fid:'image123',file_name:'Trip.HEIC',file:true,thumbnail:'https://thumb.quark.cn/p.jpg'},
 {fid:'video123',file_name:'Film.mkv',file:true,category:1}
]},metadata:{_total:2}}],true);
assert.equal(cloudPhotos.result.items.length,1);
assert.equal(cloudPhotos.result.items[0].kind,'photo');
const originalPhoto = invoke('quark','resolve',{reference:'image123',original:'true',media:'photos'},[{status:200,code:0,data:[{fid:'image123',download_url:'https://dl-pc-zb.drive.quark.cn/image.jpg'}]}],true);
assert.equal(originalPhoto.result.transport,'original-file');
checks.quarkPhotoModeFiltersVideosAndReusesOriginalFileAuthorization = true;
const mixedQuark = invoke('quark','browse',{},[{status:200,code:0,data:{list:[
 {fid:'img1',file_name:'Cover.webp',file:true,thumbnail:'https://thumb.quark.cn/p.jpg'},
 {fid:'vid1',file_name:'Film.mkv',file:true,category:1},
 {fid:'doc1',file_name:'Notes.txt',file:true}
]},metadata:{_total:3}}],true);
assert.deepEqual(mixedQuark.result.items.map(item => item.kind), ['photo','video']);
assert.equal(mixedQuark.result.items[0].preview, 'https://thumb.quark.cn/p.jpg');
checks.quarkDirectoryIncludesImagesAndVideos = true;


const music = invoke('music','search',{query:'example'},[{items:[]}]);
assert.deepEqual(music.requests,['native:music']);
assert.equal(music.requestOptions[0].query,'example');
checks.musicUsesNativeMetadata = true;

const originalQuark = invoke('quark', 'resolve', {reference: 'owned123', original: 'true'},
  [{status: 200, code: 0, data: [{fid: 'owned123', download_url: 'https://dl-pc-zb.drive.quark.cn/owned.mkv'}]}], true);
assert.equal(originalQuark.result.transport, 'original-matroska');
assert.equal(originalQuark.result.headers.Cookie, undefined);
assert.equal(originalQuark.requestOptions[0].authenticated, true);
assert.deepEqual(originalQuark.requestOptions[0].body.fids, ['owned123']);
assert.equal(new URL(originalQuark.requests[0]).pathname, '/1/clouddrive/file/download');
checks.quarkOriginalUsesAuthenticatedNativeAPIWithoutExposingCookies = true;
for (const download_url of ['https://attacker.invalid/owned.mkv', 'https://dl-pc-zb.drive.quark.cn.attacker.invalid/owned.mkv']) {
  assert.throws(() => invoke('quark', 'resolve', {reference: 'owned123', original: 'true'},
    [{status: 200, code: 0, data: [{fid: 'owned123', download_url}]}], true), /authorize/);
}
checks.quarkOriginalRejectsForeignDownloadOrigins = true;
const quarkToken = 'q'.repeat(32);
const quarkQR = invoke('quark', 'login', {step: 'start'}, [{status: 2000000, data: {members: {token: quarkToken}}}]);
assert.equal(new URL(quarkQR.result.qrURL).hostname, 'su.quark.cn');
assert.equal(new URL(quarkQR.result.qrURL).searchParams.get('token'), quarkToken);
assert.equal(quarkQR.result.state, 'waiting');
for (const [status, state] of [[50004001, 'waiting'], [50004002, 'expired']]) {
  assert.equal(invoke('quark', 'login', {step: 'poll', token: quarkToken}, [{status}]).result.state, state);
}
assert.throws(() => invoke('quark', 'login', {step: 'poll', token: quarkToken}, [{status: 2000000}]), /未返回完整/);
assert.equal(invoke('quark', 'login', {step: 'poll', token: quarkToken}, [{status: 2000000, _mtvSessionCaptured: true}]).result.state, 'authorized');
assert.throws(() => invoke('quark', 'login', {step: 'poll', token: 'injected&token=other'}), /无效/);
assert.equal(invoke('quark', 'browse').result.requiresLogin, true);
checks.quarkChallengeAndNativeSessionRequired = true;
const quarkPage = invoke('quark', 'browse', {folder: 'folder123', page: '1'}, [{status: 200, code: 0,
  data: {list: [
    {fid: 'folder456', file_name: 'Movies', file: false},
    {fid: 'video123', file_name: 'Film.mkv', file: true, category: 1, size: 2 * 1024 ** 3},
    {fid: 'text123', file_name: 'Notes.txt', file: true, category: 2}
  ]}, metadata: {_total: 51}}], true);
assert.equal(quarkPage.result.items.length, 2);
assert.equal(quarkPage.result.items[0].kind, 'folder');
assert.equal(quarkPage.result.items[1].kind, 'video');
assert.equal(quarkPage.result.items[1].subtitle, '2.0 GB');
assert.equal(quarkPage.result.next, '2');
assert.equal(new URL(quarkPage.requests[0]).searchParams.get('pdir_fid'), 'folder123');
assert.throws(() => invoke('quark', 'browse', {folder: 'folder&injected=1'}, [], true), /目录编号/);
assert.throws(() => invoke('quark', 'browse', {page: '1&other=2'}, [], true), /页码/);
assert.throws(() => invoke('quark', 'browse', {}, [{status: 401, code: 100}], true), /读取失败/);
checks.quarkFoldersPaginationAndFileFiltering = true;
const textOnlyPage = invoke('quark', 'browse', {page: '2'}, [{status: 200, code: 0,
  data: {list: [{fid: 'notes', file_name: 'Notes.txt', file: true, category: 2}]}, metadata: {_total: 101}}], true);
assert.equal(textOnlyPage.result.items.length, 0);
assert.equal(textOnlyPage.result.next, '3');
const laterVideo = invoke('quark', 'browse', {page: '3'}, [{status: 200, code: 0,
  data: {list: [{fid: 'laterVideo', file_name: 'Film.M2TS', file: true, category: 2}]}, metadata: {_total: 101}}], true);
assert.equal(laterVideo.result.items.length, 1);
assert.equal(laterVideo.result.next, undefined);
checks.quarkFilteredPagesKeepAdvancingToLaterVideo = true;
const quarkVideo = invoke('quark', 'resolve', {reference: 'video123'}, [{status: 200, code: 0, data: {video_list: [
  {resolution: '4k', video_info: {url: 'https://media.quark.cn/4k.m3u8', height: 2160}},
  {resolution: 'super', accessable: false, video_info: {url: 'https://media.quark.cn/denied.m3u8', height: 1080}},
  {resolution: 'super', video_info: {url: 'https://attacker.test/leak.m3u8', height: 1080}},
  {resolution: 'high', video_info: {url: 'https://media.quark.cn/720.m3u8', height: 720}},
  {resolution: 'super', video_info: {url: 'https://media.quark.cn/1080.m3u8', height: 1080}}
]}}], true);
assert.equal(quarkVideo.result.quality, 1080);
assert.equal(quarkVideo.result.url, 'https://media.quark.cn/1080.m3u8');
assert.equal(quarkVideo.result.headers.Referer, 'https://pan.quark.cn/');
assert.equal(quarkVideo.result.headers.Cookie, undefined);
assert.equal(quarkVideo.result.headers.Authorization, undefined);
assert.equal(quarkVideo.requestOptions[0].method, 'POST');
assert.equal(quarkVideo.requestOptions[0].authenticated, true);
assert.equal(quarkVideo.requestOptions[0].body.fid, 'video123');
assert.equal(new URL(quarkVideo.requests[0]).pathname, '/1/clouddrive/file/v2/play');
assert.equal(quarkVideo.requestOptions[0].body.supports, 'fmp4');
assert.ok(!quarkVideo.requests[0].includes('/play/project'));
assert.throws(() => invoke('quark', 'resolve', {reference: 'video123'}, [{status: 200, code: 0, data: {video_list: []}}], true), /没有可用/);
assert.throws(() => invoke('quark', 'resolve', {reference: '../file'}, [], true), /文件编号/);
checks.quarkResolutionSelectionDoesNotForwardCookies = true;
const popular = invoke('bilibili', 'browse', {page: '2'}, [{code: 0, data: {list: [{bvid: 'BVtest', title: 'Video', owner: {name: 'Author'}, pic: 'http://i0.hdslb.com/test.jpg'}], no_more: false}}]);
assert.equal(popular.result.next, '3'); assert.ok(popular.requests[0].includes('pn=2'));
checks.popularPagination = true;
const lookupInfo = {code: 0, data: {title: 'Course', desc: 'Description', pic: 'http://i0.hdslb.com/poster.jpg', owner: {name: 'Author'}, pages: [
  {cid: 101, page: 1, part: 'First'}, {cid: 202, page: 2, part: 'Second'}
]}};
const lookupBV = 'BV1wD4y1o7AS';
for (const reference of [lookupBV, ' https://www.bilibili.com/video/' + lookupBV + '/?share_source=copy#reply ']) {
  const found = invoke('bilibili', 'lookup', {reference}, [lookupInfo]);
  assert.equal(found.result.items[0].reference, lookupBV);
  assert.equal(found.result.items[0].collectionReference, lookupBV);
  assert.equal(found.requests.length, 1);
  assert.equal(new URL(found.requests[0]).pathname, '/x/web-interface/view');
}
const lookupPart = invoke('bilibili', 'lookup', {reference: 'https://bilibili.com/video/' + lookupBV + '?p=%32&share_source=copy'}, [lookupInfo]);
assert.equal(lookupPart.result.items[0].reference, lookupBV + ':202');
assert.equal(lookupPart.result.items[0].subtitle, 'Author · P2');
checks.explicitVideoLookupUsesExistingMetadataEndpointAndStablePart = true;
for (const reference of ['BVtest', 'https://b23.tv/short', 'https://bilibili.com.evil.test/video/' + lookupBV,
  'https://www.bilibili.com@evil.test/video/' + lookupBV, 'http://www.bilibili.com/video/' + lookupBV,
  'https://www.bilibili.com/video/' + lookupBV + '?p=0', 'https://www.bilibili.com/video/' + lookupBV + '?p=1001',
  'https://www.bilibili.com/video/' + lookupBV + '?p=1&p=2', 'https://www.bilibili.com/video/' + lookupBV + '?p=%FF',
  lookupBV + '\nother']) {
  assert.throws(() => invoke('bilibili', 'lookup', {reference}), /格式|请输入|参数|范围/);
}
assert.throws(() => invoke('bilibili', 'lookup', {reference: 'https://www.bilibili.com/video/' + lookupBV + '?p=3'}, [lookupInfo]), /没有所选/);
assert.throws(() => invoke('bilibili', 'lookup', {reference: lookupBV}, [{code: -404}]), /无法打开/);
checks.explicitLookupRejectsUnsupportedOrAmbiguousInputsWithoutRequests = true;
assert.equal(popular.result.items[0].collectionReference, 'BVtest');
const parts = Array.from({length: 105}, (_, index) => ({cid: index + 101, page: index + 1, part: 'Part ' + (index + 1)}));
const partInfo = {code: 0, data: {cid: 101, title: 'Course', pic: 'http://i0.hdslb.com/test.jpg', pages: parts}};
const partPage = invoke('bilibili', 'browse', {folder: 'BVtest'}, [partInfo]);
assert.equal(partPage.result.items.length, 100); assert.equal(partPage.result.next, '2');
assert.equal(partPage.result.items[0].reference, 'BVtest:101');
assert.equal(partPage.result.items[0].collectionReference, undefined);
const partTail = invoke('bilibili', 'browse', {folder: 'BVtest', page: '2'}, [partInfo]);
assert.equal(partTail.result.items.length, 5); assert.equal(partTail.result.next, undefined);
assert.equal(partTail.result.items[4].reference, 'BVtest:205');
assert.throws(() => invoke('bilibili', 'browse', {folder: 'BVtest&cid=2'}), /选集编号/);
checks.partListingUsesNativeFolderPagination = true;
const partStream = invoke('bilibili', 'resolve', {reference: 'BVtest:102'}, [partInfo,
  {code: 0, data: {durl: [{url: 'https://cdn.bilivideo.com/part2'}], quality: 64}}]);
assert.equal(new URL(partStream.requests[1]).searchParams.get('cid'), '102');
assert.equal(new URL(partStream.requests[1]).searchParams.get('bvid'), 'BVtest');
assert.equal(partStream.result.url, 'https://cdn.bilivideo.com/part2');
assert.throws(() => invoke('bilibili', 'resolve', {reference: 'BVtest:999'}, [partInfo]), /已不存在/);
assert.throws(() => invoke('bilibili', 'resolve', {reference: 'BVtest:9007199254740992'}, [partInfo]), /已不存在/);
for (const bad of ['BVtest:0', 'BVtest:01', 'BVtest:102&cid=3']) {
  assert.throws(() => invoke('bilibili', 'resolve', {reference: bad}), /视频编号/);
}
checks.selectedPartIsRevalidatedBeforePlayRequest = true;
assert.equal(partStream.result.continuation.currentReference, 'BVtest:102');
assert.equal(partStream.result.continuation.collectionReference, 'BVtest');
assert.equal(partStream.result.continuation.next.reference, 'BVtest:103');
assert.equal(partStream.result.continuation.next.url, undefined);
const acrossBoundary = invoke('bilibili', 'continuation', {reference: 'BVtest:200', collection: 'BVtest'}, [partInfo]);
assert.equal(acrossBoundary.result.next.reference, 'BVtest:201');
assert.equal(acrossBoundary.requests.length, 1);
assert.equal(invoke('bilibili', 'continuation', {reference: 'BVtest:205', collection: 'BVtest'}, [partInfo]).result.next, null);
checks.continuationUsesActualCIDAcrossFolderPagesAndExplicitLastPart = true;
assert.throws(() => invoke('bilibili', 'continuation', {reference: 'BVtest:102', collection: 'BVother'}), /范围/);
assert.throws(() => invoke('bilibili', 'continuation', {reference: 'BVtest:999', collection: 'BVtest'}, [partInfo]), /已不存在/);
assert.throws(() => invoke('bilibili', 'continuation', {reference: 'BVtest', collection: 'BVtest'}), /范围/);
checks.continuationCannotChangeVideoOrFallBackAfterRemovedCurrentPart = true;
for (const invalid of [undefined, [], [parts[0], parts[0]], [{cid: -1, page: 1, part: 'bad'}],
  [{cid: 1, page: 1, part: 'one'}, {cid: 2, page: 1, part: 'two'}], Array(1001).fill(parts[0])]) {
  assert.throws(() => invoke('bilibili', 'browse', {folder: 'BVtest'}, [{...partInfo, data: {...partInfo.data, pages: invalid}}]), /分 P 列表/);
}
checks.malformedPartListCannotSilentlySelectFirstPart = true;

const search = invoke('bilibili', 'search', {query: '猫 & dog'}, [{code: 0, data: {numPages: 3, result: [{bvid: 'BVtest', title: '<em class="keyword">猫</em> &amp; dog', author: 'Author', pic: '//i0.hdslb.com/test.jpg'}]}}]);
assert.equal(search.result.items[0].title, '猫 & dog');
assert.equal(search.result.items[0].poster, 'https://i0.hdslb.com/test.jpg');
assert.ok(search.requests[0].includes(encodeURIComponent('猫 & dog')));
checks.searchEncodingAndPlainText = true;

assert.throws(() => invoke('bilibili', 'search', {query: '猫'}, [{code: -412, message: 'Rejected'}]), /搜索失败/);
checks.searchFailureIsExplicit = true;
assert.throws(() => invoke('bilibili', 'browse', {page: '1&injection=true'}), /页码/);
checks.pageValidation = true;
assert.throws(() => invoke('bilibili', 'search', {query: 'a'.repeat(101)}), /1–100/);
checks.searchLengthValidation = true;
assert.throws(() => invoke('bilibili', 'resolve', {reference: 'bad&cid=0'}), /视频编号/);
checks.referenceValidation = true;

const example = invoke('example', 'search', {query: 'Search'});
assert.equal(example.result.items.length, 1); assert.equal(example.result.items[0].id, 'search');
checks.exampleGenericSearch = true;
const qr = invoke('bilibili', 'login', {step: 'start'}, [{code: 0, data: {url: 'https://passport.bilibili.com/qr', qrcode_key: 'a'.repeat(32)}}]);
assert.equal(qr.result.state, 'waiting'); assert.equal(qr.result.token.length, 32);
checks.loginChallenge = true;
for (const [code, state] of [[86101, 'waiting'], [86090, 'scanned'], [86038, 'expired'], [0, 'authorized']]) {
  const value = invoke('bilibili', 'login', {step: 'poll', token: 'a'.repeat(32)}, [{code: 0, data: {code}}]);
  assert.equal(value.result.state, state);
}
checks.loginStateMapping = true;
assert.throws(() => invoke('bilibili', 'login', {step: 'poll', token: 'invalid'}), /扫码会话/);
checks.loginTokenValidation = true;
for (const [hasSession, quality] of [[false, 64], [true, 80]]) {
  const stream = invoke('bilibili', 'resolve', {reference: 'BVtest', transport: 'progressive'}, [{code: 0, data: {cid: 1}}, {code: 0, data: {durl: [{url: 'https://cdn.bilivideo.com/test'}], quality}}], hasSession);
  assert.ok(stream.requests[1].includes('qn=120'));
  assert.ok(stream.requests[1].includes('platform=html5'));
  assert.ok(stream.requests[1].includes('fnval=0'));
  assert.equal(stream.result.quality, quality);
}
checks.authorizedAndGuestQualityRequests = true;
const dashData = {dash: {video: [
  {id: 120, height: 2160, codecid: 7, baseUrl: 'https://cdn.bilivideo.com/4k.m4s'},
  {id: 80, height: 1080, codecid: 12, baseUrl: 'https://cdn.bilivideo.com/hevc.m4s'},
  {id: 80, height: 1080, codecid: 7, baseUrl: 'https://cdn.bilivideo.com:448/rejected.m4s', backupUrl: ['https://cdn.bilivideo.com/avc.m4s']},
  {id: 64, height: 720, codecid: 7, baseUrl: 'https://cdn.bilivideo.com/720.m4s'}
], audio: [{id: 30280, codecs: 'mp4a.40.2', bandwidth: 192000, baseUrl: 'https://cdn.bilivideo.com/aac.m4s'}]}};
const dash = invoke('bilibili', 'resolve', {reference: 'BVtest'}, [{code: 0, data: {cid: 1}}, {code: 0, data: dashData}], true);
assert.ok(dash.requests[1].includes('platform=pc') && dash.requests[1].includes('fnval=144'));
assert.equal(dash.result.transport, 'indexed-fmp4');
assert.equal(dash.result.url, 'https://cdn.bilivideo.com/4k.m4s');
assert.equal(dash.result.audioURL, 'https://cdn.bilivideo.com/aac.m4s');
assert.equal(dash.result.quality, 120);
assert.equal(dash.requests.length, 2);
assert.equal(dash.result.headers.Cookie, undefined);
assert.equal(dash.result.headers.Referer, 'https://www.bilibili.com/');
checks.dashKeepsAuthorizedQualityAndChoosesApprovedAVCCandidate = true;
assert.ok(dash.requests[1].includes('fourk=1'));
const manualHD = invoke('bilibili', 'resolve', {reference: 'BVtest', quality: '80'}, [{code:0,data:{cid:1}}, {code:0,data:dashData}], true);
assert.equal(manualHD.result.quality, 80);
assert.equal(manualHD.result.url, 'https://cdn.bilivideo.com/avc.m4s');
const highBitrate = invoke('bilibili', 'resolve', {reference: 'BVtest'}, [{code:0,data:{cid:1}}, {code:0,data:{dash:{video:[
  {id:80,height:1080,codecid:7,baseUrl:'https://cdn.bilivideo.com/hd.m4s'},
  {id:112,height:1080,codecid:7,bandwidth:12000000,baseUrl:'https://cdn.bilivideo.com/hq.m4s'}],audio:dashData.dash.audio},
  support_formats:[{quality:112,new_description:'1080P 高码率',need_vip:true},{quality:120,new_description:'4K',need_vip:true}]}}], true);
assert.equal(highBitrate.result.quality,112);
assert.equal(highBitrate.result.qualityTitle,'1080P 高码率');
assert.equal(highBitrate.result.qualities.find(q=>q.id===120).available,false);
assert.equal(highBitrate.result.qualities.find(q=>q.id===112).available,true);
assert.throws(()=>invoke('bilibili','resolve',{reference:'BVtest',quality:'80&secret=x'},[{code:0,data:{cid:1}}]),/清晰度/);
checks.manualHDAndAuthorizedHighBitrateAndUnavailable4K = true;

const guestDash = invoke('bilibili', 'resolve', {reference: 'BVtest', transport: 'dash'}, [{code: 0, data: {cid: 1}},
  {code: 0, data: {dash: {video: [{id: 32, height: 480, baseUrl: 'https://cdn.bilivideo.com/480.m4s'}], audio: dashData.dash.audio}}}]);
assert.equal(guestDash.result.quality, 32);
assert.ok(guestDash.result.note.includes('480p'));
assert.ok(guestDash.requests[1].includes('platform=pc'));
checks.explicitGuestDashDoesNotInventHigherAuthorization = true;
assert.throws(() => invoke('bilibili', 'resolve', {reference: 'BVtest'}, [{code: 0, data: {cid: 1}},
  {code: 0, data: {dash: {video: dashData.dash.video, audio: [{id: 1, codecs: 'flac', baseUrl: 'https://cdn.bilivideo.com/flac'}]}}}], true), /未省略音频/);
checks.unsupportedAudioCannotBecomeSilentVideo = true;
assert.throws(() => invoke('bilibili', 'resolve', {reference: 'BVtest'}, [{code: 0, data: {cid: 1}},
  {code: 0, data: {dash: {video: [{id: 80, height: 1080, baseUrl: 'https://cdn.bilivideo.com.evil.test/leak'}], audio: []}}}], true), /未提供已授权/);
checks.dashRejectsUnapprovedCandidates = true;
const feedVideo = {bvid: 'BVtest', title: 'Homepage', pic: 'https://i0.hdslb.com/home.jpg', owner: {name: 'Author'}};
const home = invoke('bilibili', 'browse', {channel: 'home'}, [{code: 0, data: {item: [feedVideo, {bvid: '', title: 'Ad'}]}}]);
assert.equal(home.result.items.length, 1); assert.ok(home.requests[0].includes('/wbi/index/top/feed/rcmd?')); assert.equal(home.result.next, '2');
assert.throws(() => invoke('bilibili', 'browse', {channel: 'home'}, [{code: -352}]), /扫码登录.*-352/);
checks.homeIsASeparateRecommendationFeedWithoutSilentPopularFallback = true;
const rank = invoke('bilibili', 'browse', {channel: 'ranking'}, [{code: 0, data: {list: [feedVideo]}}]);
assert.ok(rank.requests[0].includes('/ranking/v2?')); assert.equal(rank.result.next, undefined);
checks.rankingPreservesProviderOrderWithoutInventedPagination = true;
for (const channel of ['dynamic', 'favorites']) {
  const guest = invoke('bilibili', 'browse', {channel});
  assert.equal(guest.result.requiresLogin, true); assert.equal(guest.requests.length, 0);
}
checks.privateChannelsRequireLoginWithoutAnonymousRequests = true;
const dyn = invoke('bilibili', 'browse', {channel: 'dynamic', page: 'dyn:123'}, [{code: 0, data: {offset: '456', has_more: true, items: [
  {modules: {module_author: {name: 'Followed'}, module_dynamic: {major: {archive: {bvid: 'BVtest', title: 'Posted', cover: 'https://i0.hdslb.com/test.jpg'}}}}},
  {modules: {module_dynamic: {major: {article: {id: 1}}}}}
]}}], true);
assert.equal(dyn.result.items.length, 1); assert.equal(dyn.result.next, 'dyn:456');
assert.equal(new URL(dyn.requests[0]).searchParams.get('offset'), '123'); assert.equal(dyn.requestOptions[0].authenticated, true);
assert.throws(() => invoke('bilibili', 'browse', {channel: 'dynamic', page: 'dyn:123&x=1'}, [], true), /页码/);
assert.throws(() => invoke('bilibili', 'browse', {channel: 'dynamic', page: 'dyn:123'}, [{code: 0, data: {offset: '123', has_more: true}}], true), /游标/);
assert.equal(invoke('bilibili', 'browse', {channel: 'dynamic'}, [{code: -101}], true).result.requiresLogin, true);
checks.dynamicFiltersVideosAndUsesValidatedOpaquePagination = true;
const favorites = invoke('bilibili', 'browse', {channel: 'favorites'}, [
  {code: 0, data: {mid: 42, isLogin: true}}, {code: 0, data: {list: [{id: 12345, title: '收藏', media_count: 3}], has_more: false}}
], true);
assert.equal(favorites.result.items[0].kind, 'folder'); assert.equal(favorites.result.items[0].reference, 'fav:12345');
assert.equal(new URL(favorites.requests[1]).searchParams.get('up_mid'), '42');
assert.ok(favorites.requestOptions.every(options => options.authenticated));
checks.favoritesBelongToTheValidatedCurrentAccount = true;
const favoriteVideos = invoke('bilibili', 'browse', {channel: 'favorites', folder: 'fav:12345', page: '2'}, [{code: 0, data: {has_more: true, medias: [
  {type: 2, bvid: 'BVtest', title: 'Saved', cover: 'https://i0.hdslb.com/test.jpg', upper: {name: 'UP'}},
  {type: 2, bvid: '', title: 'Deleted'}, {type: 12, bvid: 'BVtest', title: 'Audio'}
]}}], true);
assert.equal(favoriteVideos.result.items.length, 1); assert.equal(favoriteVideos.result.next, '3');
assert.equal(new URL(favoriteVideos.requests[0]).searchParams.get('media_id'), '12345');
assert.throws(() => invoke('bilibili', 'browse', {folder: 'fav:12&x=1'}, [], true), /选集编号/);
checks.favoriteFoldersPaginatePlayableVideoWithoutDeletedEntries = true;
const watchLaterVideos = Array.from({length: 21}, (_, i) => ({bvid: 'BVfixture' + i, title: 'Video ' + i}));
const watchLaterResponse = {code: 0, data: {list: [{bvid: 'BVdeleted', state: -1}, ...watchLaterVideos]}};
assert.equal(invoke('bilibili', 'browse', {channel: 'watchLater'}).result.requiresLogin, true);
const laterFirst = invoke('bilibili', 'browse', {channel: 'watchLater'}, [watchLaterResponse], true);
const laterSecond = invoke('bilibili', 'browse', {channel: 'watchLater', page: laterFirst.result.next}, [watchLaterResponse], true);
assert.deepEqual(laterFirst.result.items.map(item => item.id), watchLaterVideos.slice(0, 19).map(item => item.bvid));
assert.deepEqual(laterSecond.result.items.map(item => item.id), watchLaterVideos.slice(19).map(item => item.bvid));
assert.equal(laterSecond.result.next, undefined);
assert.ok(laterFirst.requestOptions[0].authenticated);
const paged = invoke('bilibili', 'browse', {channel: 'watchLater', page: '2'}, [
  {code: 0, data: {list: [watchLaterVideos[20]], count: 21}}
], true);
assert.equal(new URL(paged.requests[0]).searchParams.get('pn'), '2');
assert.deepEqual(paged.result.items.map(item => item.id), [watchLaterVideos[20].bvid]);
assert.equal(paged.result.next, undefined);
checks.watchLaterUsesAccountAndPreservesOrderAcrossPages = true;

console.log(JSON.stringify({checks, passed: true, count: Object.keys(checks).length}, null, 2));
