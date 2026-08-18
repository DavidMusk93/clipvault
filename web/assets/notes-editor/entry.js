import { Crepe } from '@milkdown/crepe'
import { replaceAll } from '@milkdown/utils'

async function mount(root, opts) {
  opts = opts || {}
  const upload = typeof opts.uploadImage === 'function' ? opts.uploadImage : async () => ''
  const crepe = new Crepe({
    root,
    defaultValue: opts.markdown || '',
    features: {
      [Crepe.Feature.Latex]: false,
      [Crepe.Feature.AI]: false,
      [Crepe.Feature.BlockEdit]: false,
      [Crepe.Feature.TopBar]: true,
      [Crepe.Feature.Toolbar]: true,
    },
    featureConfigs: {
      [Crepe.Feature.ImageBlock]: {
        onUpload: upload,
        inlineOnUpload: upload,
        blockOnUpload: upload,
      },
    },
  })
  if (opts.onUpdate) {
    crepe.on((api) => {
      api.markdownUpdated((_, md) => { opts.onUpdate(md) })
    })
  }
  await crepe.create()
  return {
    getMarkdown() { return crepe.getMarkdown() },
    setMarkdown(md) { crepe.editor.action(replaceAll(md || '', true)) },
    destroy() { return crepe.destroy() },
  }
}

globalThis.ClipNotesEditor = { mount }
