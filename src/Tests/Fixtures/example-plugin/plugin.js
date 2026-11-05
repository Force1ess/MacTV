/** @type {MTVPlugin} */
const plugin = {
  handle(action, input) {
    if (action === 'continuation') {
      if (input.collection !== 'example-parts' || !['example-part-1', 'example-part-2'].includes(input.reference)) throw Error('Invalid example part reference');
      return {currentReference: input.reference, collectionReference: input.collection, label: 'Next Episode',
        next: input.reference === 'example-part-1' ? {id: 'example-part-2', reference: 'example-part-2', title: 'Example · Episode 2',
          subtitle: 'P2', overview: 'Stable reference example; no media URL', source: 'example'} : null};
    }
    if (action === 'lookup') {
      if (input.reference !== 'demo') throw Error('The example accepts the demo reference only');
      return {items: [{id: 'lookup-demo', reference: 'demo', title: 'Example Opened by Reference', subtitle: 'Native Details', overview: 'This example has no media URL', source: 'example'}]};
    }
    if (action === 'resolve') throw Error('This developer example has no playable media URL');
    if (action === 'browse' && input.folder === 'example-parts') return {items: [1, 2].map(number => ({
      id: 'example-part-' + number, reference: 'example-part-' + number, title: 'Example · Episode ' + number,
      subtitle: 'P' + number, overview: 'Part selection example; no media URL', source: 'example'
    }))};
    if (action === 'browse' && input.folder === 'folder-one') return {items: [
      {id: 'folder-two', reference: 'folder-two', kind: 'folder', title: 'Nested Folder', subtitle: 'Folder', overview: 'Native folder navigation example', source: 'example'}
    ]};
    if (action === 'browse' && input.folder === 'folder-two') return {items: [
      {id: 'nested-video', title: 'Video in a Folder', subtitle: 'Nested', overview: 'This example has no media URL', source: 'example'}
    ]};
    const items = [
      { id: 'hello', title: 'Hello, MacTV', subtitle: 'No SwiftUI Required', overview: 'JavaScript supplies the card data. MacTV renders it with native SwiftUI.', collectionReference: 'example-parts', source: 'example' },
      { id: 'search', title: 'Plugin Search', subtitle: 'Native Pages & Pagination', overview: 'Search and pagination use the shared native interface.', source: 'example' }
    ];
    if (action === 'search') return { items: items.filter(item => item.title.includes(input.query || '')) };
    if (action === 'browse') return input.page === '2' ? {items: [...items.slice(1),
      {id: 'folder-one', reference: 'folder-one', kind: 'folder', title: 'Example Folder', subtitle: 'Folder', overview: 'Native folder navigation example', source: 'example'}
    ]} : {items: items.slice(0, 1), next: '2'};
    throw Error('Unsupported action');
  }
};
