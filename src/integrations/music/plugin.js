/** @type {MTVPlugin} */
const plugin = { handle(action, input) {
  if (!['browse', 'search'].includes(action)) throw Error('Unsupported music action');
  return host.library('music', {...input, reference: input.folder || input.reference || ''});
} };
