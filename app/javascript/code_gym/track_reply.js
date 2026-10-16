// Design notes: docs/code-notes/app/javascript/code_gym/track_reply.md
let unclaimed = null

export function record(reply) {
  unclaimed = reply
}

export function take() {
  const reply = unclaimed
  unclaimed = null
  return reply
}

export default { record, take }
