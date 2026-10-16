// Design notes: docs/code-notes/app/javascript/code_gym/track_reply.md
let unclaimed = null
let inFlight = 0

export function start() {
  inFlight++
}

export function finish(reply) {
  inFlight--
  if (reply) unclaimed = reply
}

export function saving() {
  return inFlight > 0
}

export function take() {
  const reply = unclaimed
  unclaimed = null
  return reply
}

export default { start, finish, saving, take }
