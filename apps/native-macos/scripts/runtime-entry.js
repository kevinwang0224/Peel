import { JSONPath } from 'jsonpath-plus'
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze)
    Object.freeze(value)
  }
  return value
}
function render(value) {
  if (value === undefined) return {status:'empty', text:'No result', structured:false}
  if (typeof value === 'function') return {status:'success', text:`[Function${value.name ? ': '+value.name : ''}]`, structured:false}
  if (typeof value === 'bigint') return {status:'success', text:String(value)+'n', structured:false}
  if (value === null || typeof value !== 'object') return {status:'success', text:String(value), structured:false}
  const text = JSON.stringify(value,null,2)
  return text === undefined ? render(undefined) : {status:'success', text, structured:true}
}
export function run(requestJSON) {
  const request = JSON.parse(requestJSON)
  const query = request.query.trim()
  if (!query) throw Error('Expression required')
  const data = freeze(JSON.parse(request.text))
  let value
  if (request.mode === 'jsonpath') {
    const matches = JSONPath({path:query,json:data,wrap:true})
    value = matches.length === 1 ? matches[0] : matches.length ? matches : undefined
  } else {
    value = new Function('data','"use strict"; return ('+query+');')(data)
  }
  Promise.resolve(value)
    .then(value => render(value))
    .then(result => peelComplete(JSON.stringify(result)))
    .catch(error => peelComplete(JSON.stringify({
      status:'error', text:String(error?.message ?? error), structured:false
    })))
}
