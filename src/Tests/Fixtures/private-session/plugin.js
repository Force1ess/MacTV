const plugin = {handle(action, input) {
  if (input.mode === 'denied-origin') return host.fetchJSON('https://auth.example.test/qr', {authenticated: true});
  if (input.mode === 'denied-login-path') return host.fetchJSON('https://AUTH.EXAMPLE.TEST/unlisted');
  if (input.mode === 'denied-post') return host.fetchJSON('https://api.example.test/file/delete', {method: 'POST', body: {fid: 'TEST_ONLY'}});
  if (input.mode === 'denied-method') return host.fetchJSON('https://api.example.test/file', {method: 'DELETE'});
  return {requestKeys: Object.keys(__request).sort(), leaked: !!__request.credential,
    sessionAvailable: host.sessionAvailable, cookieReadable: 'cookie' in host};
}};
