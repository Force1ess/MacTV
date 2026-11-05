// Original adapter. Sessions stay in the native broker; no Cookie strings enter this script.
/** @typedef {{bvid: string, title: string, desc?: string, pic: string, owner: {name: string}}} BiliVideo */
/** @typedef {{id: number, baseUrl?: string, base_url?: string, backupUrl?: string[], backup_url?: string[], codecs?: string, codecid?: number, height?: number, bandwidth?: number}} BiliDashTrack */
/** @typedef {{cid: number, page: number, part: string, duration?: number}} BiliPart */
/** @type {MTVPlugin} */
const plugin = {
  handle(action, input) {
    if (action === 'lookup') {
      const target = lookupTarget(input.reference || '');
      const response = /** @type {{code: number, data?: {title: string, desc?: string, pic: string, owner: {name: string}, pages?: BiliPart[]}}} */
        (host.fetchJSON('https://api.bilibili.com/x/web-interface/view?bvid=' + target.bvid));
      if (response.code !== 0 || !response.data) throw Error('无法打开这个视频：' + response.code);
      const data = response.data;
      const part = target.page === undefined ? undefined : validatedParts(data.pages).find(value => value.page === target.page);
      if (target.page !== undefined && !part) throw Error('这个视频没有所选分 P，请检查链接中的 p 参数');
      const reference = target.bvid + (part ? ':' + part.cid : '');
      return {items: [{id: reference, reference, collectionReference: target.bvid,
        title: part ? data.title + ' · ' + part.part : data.title,
        subtitle: data.owner.name + (part ? ' · P' + part.page : ''), overview: data.desc || '',
        poster: data.pic.replace(/^http:/, 'https:'), source: 'bilibili'}]};
    }
    if (action === 'login') {
      if (input.step === 'start') {
        const r = /** @type {{code: number, data: {url: string, qrcode_key: string}}} */
          (host.fetchJSON('https://passport.bilibili.com/x/passport-login/web/qrcode/generate'));
        if (r.code !== 0) throw Error('生成登录二维码失败：' + r.code);
        return {state: 'waiting', qrURL: r.data.url, token: r.data.qrcode_key,
          expiresAt: Date.now() / 1000 + 180, message: '使用哔哩哔哩手机客户端扫码，并在手机上确认登录'};
      }
      if (input.step === 'poll') {
        if (!/^[a-fA-F0-9]{32}$/.test(input.token || '')) throw Error('无效的扫码会话');
        const r = /** @type {{code: number, data: {code: number}}} */
          (host.fetchJSON('https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=' + input.token, {captureSession: true}));
        if (r.code !== 0) throw Error('登录状态查询失败：' + r.code);
        if (r.data.code === 0) return {state: 'authorized', message: '登录完成'};
        if (r.data.code === 86101) return {state: 'waiting', message: '等待扫码'};
        if (r.data.code === 86090) return {state: 'scanned', message: '扫码成功，请在手机上确认'};
        if (r.data.code === 86038) return {state: 'expired', message: '二维码已过期，请重新生成'};
        throw Error('未知登录状态：' + r.data.code);
      }
      throw Error('不支持的登录步骤');
    }
    const channel = input.channel || 'popular';
    if (!['popular', 'ranking', 'home', 'dynamic', 'favorites', 'watchLater'].includes(channel)) throw Error('未知的内容栏目');
    const cursor = action === 'browse' && channel === 'dynamic' && /^dyn:[0-9]{1,40}$/.test(input.page || '') ? (input.page || '').slice(4) : '';
    const page = Number(cursor ? '1' : input.page || '1');
    if (!Number.isInteger(page) || page < 1 || page > 50) throw Error('页码超出允许范围');
    if (action === 'browse') {
      if (input.folder && /^fav:[1-9][0-9]{0,19}$/.test(input.folder)) {
        if (!host.sessionAvailable) return {items: [], requiresLogin: true};
        const r = /** @type {{code: number, data?: {medias?: BiliFavoriteVideo[], has_more?: boolean}}} */
          (host.fetchJSON('https://api.bilibili.com/x/v3/fav/resource/list?media_id=' + input.folder.slice(4) + '&ps=20&pn=' + page + '&order=mtime&platform=web', {authenticated: true}));
        if (r.code === -101) return {items: [], requiresLogin: true};
        if (r.code !== 0 || !r.data) throw Error('收藏夹读取失败：' + r.code);
        return {items: (r.data.medias || []).filter(v => v.type === 2 && validCardBV(v.bvid)).map(v => videoCard({bvid: v.bvid, title: v.title, pic: v.cover, desc: v.intro, owner: v.upper})),
          next: r.data.has_more && page < 50 ? String(page + 1) : undefined};
      }
      if (input.folder) {
        if (!/^BV[a-zA-Z0-9]{1,32}$/.test(input.folder)) throw Error('无效的视频选集编号');
        const info = /** @type {{code: number, data?: {title: string, pic: string, desc?: string, owner?: {name: string}, pages?: BiliPart[]}}} */
          (host.fetchJSON('https://api.bilibili.com/x/web-interface/view?bvid=' + input.folder));
        if (info.code !== 0 || !info.data) throw Error('无法读取视频选集：' + info.code);
        const data = info.data;
        const parts = validatedParts(data.pages);
        const start = (page - 1) * 100;
        return {items: parts.slice(start, start + 100).map(part => partCard(input.folder, part, parts.length, data)),
          next: start + 100 < parts.length ? String(page + 1) : undefined};
      }
      if (channel !== 'popular') return channelPage(channel, page, cursor);
      const r = /** @type {{code: number, data: {list: BiliVideo[], no_more?: boolean}}} */ (host.fetchJSON('https://api.bilibili.com/x/web-interface/popular?ps=20&pn=' + page, {authenticated: host.sessionAvailable}));
      if (r.code !== 0) throw Error('哔哩哔哩接口错误：' + r.code);
      return { next: r.data.list.length && !r.data.no_more && page < 50 ? String(page + 1) : undefined, items: r.data.list.map(v => ({
        id: v.bvid, reference: v.bvid, collectionReference: v.bvid, title: v.title,
        subtitle: v.owner.name, overview: v.desc || '',
        poster: v.pic.replace(/^http:/, 'https:'), source: 'bilibili'
      })) };
    }
    if (action === 'search') {
      const query = (input.query || '').trim();
      if (!query || query.length > 100) throw Error('请输入 1–100 字的搜索词');
      // This public endpoint is verified independently. No cookie extraction, login
      // impersonation, WBI bypass, or automatic switch to another endpoint.
      const r = /** @type {{code: number, message?: string, data: {numPages?: number, result?: {bvid: string, title: string, author: string, pic: string, description?: string}[]}}} */
        (host.fetchJSON('https://api.bilibili.com/x/web-interface/search/type?search_type=video&page=' + page + '&keyword=' + encodeURIComponent(query), {authenticated: host.sessionAvailable}));
      if (r.code !== 0) throw Error('搜索失败：' + r.code + ' ' + (r.message || ''));
      const results = r.data.result || [];
      return { next: page < Math.min(50, r.data.numPages || 1) ? String(page + 1) : undefined,
        items: results.map(v => ({id: v.bvid, reference: v.bvid, collectionReference: v.bvid,
          title: plainText(v.title), subtitle: plainText(v.author), overview: plainText(v.description || ''),
          poster: (v.pic.startsWith('//') ? 'https:' + v.pic : v.pic).replace(/^http:/, 'https:'), source: 'bilibili'})) };
    }
    if (action === 'continuation') {
      const reference = (input.reference || '').match(/^(BV[a-zA-Z0-9]{1,32}):([1-9][0-9]{0,15})$/);
      if (!reference || input.collection !== reference[1]) throw Error('选集范围或当前分 P 引用不匹配');
      const info = /** @type {{code: number, data?: BiliPartInfo}} */ (host.fetchJSON('https://api.bilibili.com/x/web-interface/view?bvid=' + reference[1]));
      if (info.code !== 0 || !info.data) throw Error('无法核对后续分 P：' + info.code);
      return partContinuation(reference[1], Number(reference[2]), validatedParts(info.data.pages), info.data);
    }
    if (action === 'resolve') {
      const reference = (input.reference || '').match(/^(BV[a-zA-Z0-9]{1,32})(?::([1-9][0-9]{0,15}))?$/);
      if (!reference) throw Error('无效的视频编号');
      const bvid = reference[1];
      const info = /** @type {{code: number, data: {cid: number, pages?: BiliPart[], desc?: string, owner?: {name?: string}}}} */ (host.fetchJSON('https://api.bilibili.com/x/web-interface/view?bvid=' + bvid));
      if (info.code !== 0) throw Error('无法读取视频信息：' + info.code);
      const videoOwner = typeof info.data.owner?.name === 'string' ? plainText(info.data.owner.name).slice(0, 160) : undefined;
      const videoOverview = typeof info.data.desc === 'string' ? plainText(info.data.desc).slice(0, 2000) : undefined;
      let cid = info.data.cid;
      if (reference[2]) {
        const selected = Number(reference[2]);
        if (!Number.isSafeInteger(selected) || !validatedParts(info.data.pages).some(part => part.cid === selected)) {
          throw Error('所选分 P 已不存在，请返回重新选集');
        }
        cid = selected;
      }
      if (!Number.isSafeInteger(cid) || cid < 1) throw Error('平台返回了无效的分 P 编号');
      const continuation = info.data.pages === undefined ? undefined : partContinuation(bvid, cid, validatedParts(info.data.pages), info.data);
      const requestedQuality = input.quality && input.quality !== 'auto' ? Number(input.quality) : 120;
      if (!Number.isInteger(requestedQuality) || requestedQuality < 1 || requestedQuality > 120) throw Error('未知的清晰度选项');
      if (input.transport && !['dash', 'progressive'].includes(input.transport)) throw Error('未知的播放传输选项');
      // Prefer the measured native indexed path; explicit progressive remains
      // available for compatibility. Never switch after playback has started.
      const useDash = input.transport !== 'progressive';
      const r = /** @type {{code: number, data: {dash?: {video?: BiliDashTrack[], audio?: BiliDashTrack[]}, durl?: {url: string, backup_url?: string[]}[], quality: number, support_formats?: {quality: number, new_description?: string, display_desc?: string, need_login?: boolean, need_vip?: boolean}[]}}} */ (host.fetchJSON('https://api.bilibili.com/x/player/playurl?bvid=' + bvid + '&cid=' + cid + '&qn=' + requestedQuality + '&fnval=' + (useDash ? 144 : 0) + '&fnver=0&fourk=1&platform=' + (useDash ? 'pc' : 'html5') + '&high_quality=1', {authenticated: host.sessionAvailable}));
      if (r.code !== 0) throw Error('获取播放地址失败：' + r.code);
      const headers = {'Referer': 'https://www.bilibili.com/', 'User-Agent': 'Mozilla/5.0 MTVPrototype/0.1'};
      if (r.data.dash) {
        const compatible = (r.data.dash.video || []).filter(v => Number.isInteger(v.id) && v.id > 0 && v.id <= 120 && (v.codecid === undefined || v.codecid === 7) &&
          Number.isFinite(v.height) && (v.height || 0) > 0 && (v.height || 0) <= 8192 && mediaURL(v));
        const videos = compatible.filter(v => v.id <= requestedQuality)
          .sort((a, b) => b.id - a.id || Number(b.codecid === 7) - Number(a.codecid === 7) ||
            (b.bandwidth || 0) - (a.bandwidth || 0));
        if (!videos.length) throw Error('平台未提供已授权且兼容的媒体地址；可尝试最高可用画质或检查平台登录');
        const audio = r.data.dash.audio || [];
        const sounds = audio.filter(a => /^mp4a\./.test(a.codecs || '') && mediaURL(a))
          .sort((a, b) => (b.bandwidth || 0) - (a.bandwidth || 0));
        if (audio.length && !sounds.length) throw Error('平台返回的音轨格式当前不支持，未省略音频播放');
        if (!sounds.length) throw Error('当前索引传输需要平台提供可用音轨');
        const formats = r.data.support_formats || [];
        /** @param {number} q */
        const title = q => {
          const format = formats.find(f => f.quality === q);
          const track = compatible.find(v => v.id === q);
          return plainText(format && (format.new_description || format.display_desc) || (track ? track.height + 'p' : '画质 ' + q)).slice(0, 100);
        };
        const codes = [...new Set([...compatible.map(v => v.id), ...formats.map(f => f.quality).filter(q => q > 0 && q <= 120)])].sort((a,b) => b-a).slice(0,32);
        const qualities = codes.map(id => { const f = formats.find(f => f.quality === id); const available = compatible.some(v => v.id === id);
          return {id, title: title(id), available, reason: available ? '' : (r.data.dash?.video || []).some(v => v.id === id) ? '此档编码或片源格式暂不支持' : f && f.need_login ? (host.sessionAvailable ? '平台未返回此档位，请重新登录确认' : '需要登录') : f && f.need_vip ? '需要平台会员权限' : '此视频暂未提供'}; });
        return {url: mediaURL(videos[0]), audioURL: mediaURL(sounds[0]), transport: 'indexed-fmp4', videoOwner, videoOverview,
          quality: videos[0].id, qualityTitle: title(videos[0].id), qualities, height: videos[0].height, bandwidth: videos[0].bandwidth, headers, continuation,
          note: '实际 ' + title(videos[0].id) + ' · ' + videos[0].height + 'p · ' + (host.sessionAvailable ? '已附平台登录信息' : '游客授权范围')};
      }
      if (!r.data.durl || r.data.durl.length !== 1) throw Error('平台未提供单文件或 DASH 地址；多段拼接仍待适配');
      const progressive = mediaURL({id: r.data.quality, baseUrl: r.data.durl[0].url, backup_url: r.data.durl[0].backup_url});
      if (!progressive) throw Error('平台未提供允许域名和端口的单文件媒体地址');
      return { url: progressive, quality: r.data.quality, headers, continuation, videoOwner, videoOverview,
        qualityTitle: '画质 ' + r.data.quality, qualities: [{id:r.data.quality, title:'画质 ' + r.data.quality, available:true}], note: '平台返回画质 ' + r.data.quality };
    }
    throw Error('不支持的操作：' + action);
  }
};

/** @typedef {{bvid: string, title: string, cover: string, intro?: string, type: number, upper: {name: string}}} BiliFavoriteVideo */
/** @param {string} value */
function validCardBV(value) { return typeof value === 'string' && /^BV[a-zA-Z0-9]{1,32}$/.test(value); }
/** @param {BiliVideo} v @returns {MTVMediaItem} */
function videoCard(v) {
  return {id: v.bvid, reference: v.bvid, collectionReference: v.bvid, title: plainText(v.title),
    subtitle: v.owner ? plainText(v.owner.name) : '', overview: plainText(v.desc || ''),
    poster: v.pic ? (v.pic.startsWith('//') ? 'https:' + v.pic : v.pic).replace(/^http:/, 'https:') : undefined, source: 'bilibili'};
}
/** @param {string} channel @param {number} page @param {string} cursor @returns {MTVPage} */
function channelPage(channel, page, cursor) {
  if (channel === 'home' || channel === 'ranking') {
    const url = channel === 'home'
      ? 'https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd?fresh_type=3&ps=20&fresh_idx=' + page + '&fresh_idx_1h=' + page + '&feed_version=V8&homepage_ver=1&y_num=4&last_y_num=4'
      : 'https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all';
    const r = /** @type {{code: number, data?: {item?: BiliVideo[], list?: BiliVideo[]}}} */ (host.fetchJSON(url, {authenticated: host.sessionAvailable}));
    if (r.code === -352) throw Error('B站暂时限制了当前访问。请在上方账号入口扫码登录，再返回此栏目重试（-352）。');
    if (r.code !== 0 || !r.data) throw Error((channel === 'home' ? '首页推荐' : '排行榜') + '读取失败：' + r.code);
    const videos = (channel === 'home' ? r.data.item : r.data.list) || [];
    return {items: videos.filter(v => validCardBV(v.bvid)).map(videoCard),
      next: channel === 'home' && videos.length > 0 && page < 50 ? String(page + 1) : undefined};
  }
  if (!host.sessionAvailable) return {items: [], requiresLogin: true};
  if (channel === 'watchLater') {
    const r = /** @type {{code: number, data?: {list?: (BiliVideo & {state?: number})[] | null, count?: number, has_more?: boolean}}} */
      (host.fetchJSON('https://api.bilibili.com/x/v2/history/toview/web?pn=' + page + '&ps=20', {authenticated: true}));
    if (r.code === -101) return {items: [], requiresLogin: true};
    if (r.code !== 0 || !r.data) throw Error('稍后再看读取失败：' + r.code);
    if (r.data.list != null && !Array.isArray(r.data.list)) throw Error('稍后再看列表格式无效');
    const list = r.data.list ?? [];
    const start = (page - 1) * 20;
    const unpaged = list.length > 20;
    const rows = unpaged ? list.slice(start, start + 20) : list;
    const more = unpaged ? start + 20 < list.length
      : r.data.has_more ?? (rows.length > 0 && page * 20 < (r.data.count ?? page * 20));
    const seen = new Set();
    const items = rows.filter(v => {
      if (!v || !validCardBV(v.bvid) || typeof v.title !== 'string' || !v.title.trim()
        || (v.state ?? 0) < 0 || seen.has(v.bvid)) return false;
      seen.add(v.bvid);
      return true;
    }).map(videoCard);
    return {items, next: more && page < 50 ? String(page + 1) : undefined};
  }
  if (channel === 'dynamic') {
    const r = /** @type {{code: number, data?: {items?: BiliDynamic[], offset?: string, has_more?: boolean}}} */
      (host.fetchJSON('https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all?type=video&timezone_offset=-480' + (cursor ? '&offset=' + encodeURIComponent(cursor) : ''), {authenticated: true}));
    if (r.code === -101) return {items: [], requiresLogin: true};
    if (r.code !== 0 || !r.data) throw Error('动态读取失败：' + r.code);
    const items = (r.data.items || []).flatMap(v => {
      const archive = v.modules?.module_dynamic?.major?.archive;
      return archive && validCardBV(archive.bvid) ? [videoCard({bvid: archive.bvid, title: archive.title, pic: archive.cover,
        desc: archive.desc, owner: {name: v.modules?.module_author?.name || ''}})] : [];
    });
    const offset = r.data.offset || '';
    if (r.data.has_more && (!/^[0-9]{1,40}$/.test(offset) || offset === cursor)) throw Error('动态分页游标无效');
    return {items, next: r.data.has_more ? 'dyn:' + offset : undefined};
  }
  const nav = /** @type {{code: number, data?: {mid?: number, isLogin?: boolean}}} */
    (host.fetchJSON('https://api.bilibili.com/x/web-interface/nav', {authenticated: true}));
  if (nav.code === -101 || nav.data?.isLogin === false) return {items: [], requiresLogin: true};
  const mid = nav.data?.mid;
  if (nav.code !== 0 || !Number.isSafeInteger(mid) || !mid || mid < 1) throw Error('无法核对收藏夹所属账号');
  const r = /** @type {{code: number, data?: {list?: {id: number, title: string, media_count?: number}[], has_more?: boolean}}} */
    (host.fetchJSON('https://api.bilibili.com/x/v3/fav/folder/created/list?up_mid=' + mid + '&ps=20&pn=' + page, {authenticated: true}));
  if (r.code === -101) return {items: [], requiresLogin: true};
  if (r.code !== 0 || !r.data) throw Error('收藏夹列表读取失败：' + r.code);
  return {items: (r.data.list || []).filter(v => Number.isSafeInteger(v.id) && v.id > 0).map(v => ({
    id: 'fav:' + v.id, reference: 'fav:' + v.id, kind: 'folder', title: plainText(v.title),
    subtitle: (v.media_count || 0) + ' 个视频', overview: '打开收藏夹浏览视频', source: 'bilibili'})),
    next: r.data.has_more && page < 50 ? String(page + 1) : undefined};
}
/** @typedef {{modules?: {module_author?: {name?: string}, module_dynamic?: {major?: {archive?: {bvid: string, title: string, cover: string, desc?: string}}}}}} BiliDynamic */

/** Parse only an exact BV or a standard provider URL. The supplied URL is never fetched.
 * @param {string} value @returns {{bvid: string, page?: number}} */
function lookupTarget(value) {
  const text = value.trim();
  if (text.length > 2048 || /[\x00-\x1f\x7f]/.test(text)) throw Error('视频编号或链接格式无效');
  if (/^BV[a-zA-Z0-9]{10}$/.test(text)) return {bvid: text};
  const match = text.match(/^https:\/\/(?:www\.)?bilibili\.com\/video\/(BV[a-zA-Z0-9]{10})\/?(?:\?([^#\s]*))?(?:#[^\s]*)?$/);
  if (!match) throw Error('请输入完整 BV 号或 bilibili.com/video 标准链接；短链接暂不支持');
  let page;
  for (const field of (match[2] || '').split('&').filter(Boolean)) {
    const parts = field.split('=');
    let key;
    try { key = decodeURIComponent(parts[0]); } catch (_) { throw Error('链接参数无效'); }
    if (key !== 'p') continue;
    if (page !== undefined) throw Error('链接包含重复的 p 参数');
    let number;
    try { number = decodeURIComponent(parts.slice(1).join('=')); } catch (_) { throw Error('分 P 参数无效'); }
    if (!/^[1-9][0-9]{0,3}$/.test(number) || Number(number) > 1000) throw Error('分 P 参数超出范围');
    page = Number(number);
  }
  return {bvid: match[1], page};
}

/** @param {BiliPart[] | undefined} parts @returns {BiliPart[]} */
function validatedParts(parts) {
  if (!Array.isArray(parts) || !parts.length || parts.length > 1000) throw Error('平台未返回有效分 P 列表');
  const cids = new Set();
  const numbers = new Set();
  for (const part of parts) {
    if (!part || !Number.isSafeInteger(part.cid) || part.cid < 1 || !Number.isSafeInteger(part.page) || part.page < 1 ||
        typeof part.part !== 'string' || cids.has(part.cid) || numbers.has(part.page)) throw Error('平台返回了无效分 P 列表');
    cids.add(part.cid); numbers.add(part.page);
  }
  const ordered = parts.slice().sort((a, b) => a.page - b.page);
  if (!ordered.every((part, index) => part.page === index + 1)) throw Error('平台返回了不连续的分 P 列表');
  return ordered;
}

/** @typedef {{cid?: number, title?: string, pic?: string, desc?: string, owner?: {name?: string}, pages?: BiliPart[]}} BiliPartInfo */
/** @param {string} bvid @param {BiliPart} part @param {number} count @param {BiliPartInfo} info @returns {MTVMediaItem} */
function partCard(bvid, part, count, info) {
  return {id: bvid + ':' + part.cid, reference: bvid + ':' + part.cid,
    title: part.part.trim() || '第 ' + part.page + ' 分 P', subtitle: 'P' + part.page + ' / ' + count,
    overview: typeof info.desc === 'string' ? info.desc : '',
    poster: typeof info.pic === 'string' ? info.pic.replace(/^http:/, 'https:') : undefined, source: 'bilibili'};
}
/** @param {string} bvid @param {number} cid @param {BiliPart[]} parts @param {BiliPartInfo} info @returns {MTVContinuation} */
function partContinuation(bvid, cid, parts, info) {
  const index = parts.findIndex(part => part.cid === cid);
  if (!Number.isSafeInteger(cid) || index < 0) throw Error('当前分 P 已不存在，请返回重新选集');
  return {currentReference: bvid + ':' + cid, collectionReference: bvid, label: '下一P',
    next: index + 1 < parts.length ? partCard(bvid, parts[index + 1], parts.length, info) : null};
}

/** Pick only provider-supplied candidates that fit the declared transport policy; no retry or endpoint switch.
 * @param {BiliDashTrack} track */
function mediaURL(track) {
  const candidates = [track.baseUrl || track.base_url || '', ...(track.backupUrl || track.backup_url || [])];
  for (const candidate of candidates) {
    if (typeof candidate !== 'string') continue;
    const url = candidate.replace(/^http:/, 'https:');
    if (/^https:\/\/(?:[a-zA-Z0-9-]+\.)*(?:bilivideo\.com|bilivideo\.cn|akamaized\.net)(?::443)?\//.test(url)) return url;
  }
  return '';
}

/** @param {string} text */
function plainText(text) {
  return text.replace(/<[^>]*>/g, '').replace(/&(amp|lt|gt|quot|apos);/g, token =>
    /** @type {Record<string, string>} */ ({'&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'"})[token] || token);
}
