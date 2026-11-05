// No background collection, storage, telemetry, or console logging.
document.getElementById('import').addEventListener('click', async () => {
  const button = document.getElementById('import');
  const status = document.getElementById('status');
  button.disabled = true;
  status.textContent = '正在由 MTV 验证会话…';
  try {
    const provider = document.getElementById('provider').value;
    if (!['mtv.quark', 'mtv.bilibili'].includes(provider)) throw new Error('Invalid provider');
    const bili = provider === 'mtv.bilibili';
    const allowed = new Set(bili ? ['SESSDATA', 'bili_jct', 'DedeUserID', 'DedeUserID__ckMd5'] : ['__pus', '__puus', '__kps', '__uid']);
    const cookies = (await chrome.cookies.getAll({url: bili ? 'https://api.bilibili.com/' : 'https://drive.quark.cn/'}))
      .filter(cookie => allowed.has(cookie.name))
      .map(({name, value, domain, path, hostOnly, expirationDate}) => ({name, value, domain, path, hostOnly, expirationDate}));
    if (!cookies.some(cookie => bili ? cookie.name === 'SESSDATA' : cookie.name === '__pus' || cookie.name === '__puus')) {
      status.textContent = '此Chrome资料没有所选平台的登录，请先在这份资料中登录。';
      return;
    }
    const response = await chrome.runtime.sendNativeMessage('local.mtv.quark_bridge', {schema: 1, provider, cookies});
    status.textContent = response?.ok === true ? 'MTV 已通过平台验证并保存在此Mac，可以返回 MTV。' : '平台验证未通过。请在此Chrome重新登录后导入，或使用扫码登录。';
  } catch {
    status.textContent = '未连接到 MTV。请先在 MTV 平台登录页点击“从Chrome导入”，确认连接组件已加载。';
  } finally { button.disabled = false; }
});
