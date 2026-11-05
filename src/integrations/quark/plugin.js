// Original adapter. Native code redeems the ticket; account secrets stay native.
/** @type {MTVPlugin} */
const plugin = {
  handle(action, input) {
    if (action === 'browse') {
      if (!host.sessionAvailable) return {items: [], requiresLogin: true};
      const folder = input.folder || '0';
      const page = Number(input.page || '1');
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(folder)) throw Error('无效的夸克目录编号');
      if (!Number.isInteger(page) || page < 1 || page > 2000) throw Error('目录页码超出范围');
      const size = 50;
      const response = /** @type {{code: number, status: number, data?: {list?: {fid: string, file_name: string, file: boolean, category?: number, size?: number, thumbnail?: string}[]}, metadata?: {_total?: number}}} */
        (host.fetchJSON('https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=' +
          encodeURIComponent(folder) + '&_page=' + page + '&_size=' + size +
          '&_fetch_total=1&fetch_all_file=1&_sort=file_type:asc,file_name:asc', {authenticated: true}));
      if (response.code !== 0 || response.status !== 200 || !Array.isArray(response.data?.list)) {
        throw Error('夸克目录读取失败，请检查登录状态：' + response.code);
      }
      const files = response.data.list;
      const photos = input.media === 'photos';
      const items = files.filter(file => file.file === false || (file.file === true && (photos
        ? /\.(jpg|jpeg|png|heic|heif|webp|gif|tif|tiff|bmp|avif)$/i.test(file.file_name)
        : (file.category === 1 || /\.(mkv|mp4|m4v|mov|avi|webm|ts|m2ts|mts|mpg|mpeg|wmv|flv|rmvb|asf|vob|ogv)$/i.test(file.file_name))))).map(file => {
        if (!/^[A-Za-z0-9_-]{1,128}$/.test(file.fid) || typeof file.file_name !== 'string' || !file.file_name.trim()) {
          throw Error('夸克返回了无效文件信息');
        }
        return {id: file.fid, reference: file.fid, title: file.file_name,
          kind: /** @type {'folder' | 'video' | 'photo'} */ (file.file === false ? 'folder' : photos ? 'photo' : 'video'),
          preview: photos && typeof file.thumbnail === 'string' ? file.thumbnail : undefined,
          subtitle: file.file === false ? '文件夹' : fileSize(file.size),
          overview: '', source: 'mtv.quark'};
      });
      const total = response.metadata?._total;
      const more = typeof total === 'number' && Number.isFinite(total) ? page * size < total : files.length === size;
      return {items, next: more && page < 2000 ? String(page + 1) : undefined};
    }
    if (action === 'resolve') {
      if (!host.sessionAvailable) throw Error('请先扫码登录夸克网盘');
      if (!/^[A-Za-z0-9_-]{1,128}$/.test(input.reference || '')) throw Error('无效的夸克文件编号');
      if (input.original === 'true') {
        const response = /** @type {{code: number,status: number,data?: {fid?: string,download_url?: string}[]}} */
          (host.fetchJSON('https://drive.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc',
            {authenticated: true, method: 'POST', body: {fids: [input.reference]}}));
        const file = response.data?.[0];
        if (response.code !== 0 || response.status !== 200 || !file?.download_url ||
          (file.fid && file.fid !== input.reference) || response.data?.length !== 1 ||
          !/^https:\/\/dl-pc(?:-[a-z0-9]+)+\.drive\.quark\.cn(?::443)?\//.test(file.download_url)) {
          throw Error('Quark did not authorize an original-file stream.');
        }
        return {url: file.download_url, transport: input.media === 'photos' ? 'original-file' : 'original-matroska',
          headers: {'Referer': 'https://pan.quark.cn/',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch'},
          note: 'Original · embedded audio and subtitles'};
      }
      const response = /** @type {{code: number, status: number, data?: {video_list?: {resolution: string, accessable?: boolean, video_info?: {url?: string, height?: number, width?: number, success?: boolean}}[]}}} */
        (host.fetchJSON('https://drive.quark.cn/1/clouddrive/file/v2/play?pr=ucpro&fr=pc',
          {authenticated: true, method: 'POST', body: {fid: input.reference,
            resolutions: 'low,normal,high,super,2k,4k', supports: 'fmp4'}}));
      if (response.code !== 0 || response.status !== 200 || !Array.isArray(response.data?.video_list)) {
        throw Error('夸克未返回可播放的转码信息：' + response.code);
      }
      const resolutions = /** @type {Record<string, number>} */ ({low: 360, normal: 480, high: 720, super: 1080, '2k': 1440, '4k': 2160});
      const candidates = response.data.video_list.filter(stream => stream.accessable !== false && stream.video_info?.success !== false)
        .map(stream => ({url: stream.video_info?.url || '',
          quality: stream.video_info?.height || resolutions[stream.resolution] || 0}))
        .filter(stream => stream.quality > 0 && stream.quality <= 1080 &&
          /^https:\/\/(?:[a-zA-Z0-9-]+\.)*(?:quark\.cn|quark\.com\.cn|uc\.cn)(?::443)?\//.test(stream.url))
        .sort((a, b) => b.quality - a.quality);
      if (!candidates.length) throw Error('当前账号没有可用的 1080p 或较低清晰度流；未转发账号 Cookie 到媒体地址');
      return {url: candidates[0].url, quality: candidates[0].quality,
        headers: {'Referer': 'https://pan.quark.cn/',
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15'},
        note: '夸克网盘 · ' + candidates[0].quality + 'p'};
    }
    if (action !== 'login') throw Error('不支持的夸克操作');
    const query = 'client_id=532&v=1.2&request_id=' + requestID();
    if (input.step === 'start') {
      const response = /** @type {{status: number, data?: {members?: {token?: string}}}} */
        (host.fetchJSON('https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?' + query));
      const token = response.data?.members?.token || '';
      if (response.status !== 2000000 || !validToken(token)) throw Error('夸克未返回有效扫码会话');
      return {state: 'waiting', token,
        qrURL: 'https://su.quark.cn/4_eMHBJ?token=' + encodeURIComponent(token) +
          '&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=' +
          encodeURIComponent('S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0'),
        expiresAt: Date.now() / 1000 + 180, message: '使用夸克手机客户端扫码，并在手机上确认登录'};
    }
    if (input.step === 'poll') {
      if (!validToken(input.token || '')) throw Error('无效的夸克扫码会话');
      const response = /** @type {{status: number, _mtvSessionCaptured?: boolean}} */
        (host.fetchJSON('https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?' + query +
          '&token=' + encodeURIComponent(input.token), {captureSession: true}));
      if (response._mtvSessionCaptured === true) return {state: 'authorized', message: '登录完成'};
      if (response.status === 50004001) return {state: 'waiting', message: '等待扫码并确认'};
      if (response.status === 50004002) return {state: 'expired', message: '二维码已过期'};
      if (response.status === 2000000) throw Error('平台未返回完整的登录会话，未保存登录状态');
      throw Error('夸克拒绝登录或已取消：' + response.status);
    }
    throw Error('不支持的登录步骤');
  }
};

/** @param {string} token */
function validToken(token) { return /^[A-Za-z0-9_-]{16,128}$/.test(token); }
function requestID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, letter => {
    const value = Math.floor(Math.random() * 16);
    return (letter === 'x' ? value : (value & 3) | 8).toString(16);
  });
}
/** @param {number | undefined} size */
function fileSize(size) {
  if (typeof size !== 'number' || !Number.isFinite(size) || size < 0) return '视频';
  return size >= 1024 ** 3 ? (size / 1024 ** 3).toFixed(1) + ' GB' : (size / 1024 ** 2).toFixed(1) + ' MB';
}
