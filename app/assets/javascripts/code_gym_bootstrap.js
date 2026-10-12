// Holds page-script calls made before the deferred modules run; docs/code-notes/app/assets/javascripts/code_gym_bootstrap.md
(function () {
  var waiting = []
  var probes = []
  var open = Object.create(null)
  var early = { dirty: false }

  function recordEdit(event) {
    var target = event.target
    if (target && target.closest && target.closest("[data-controller]")) early.dirty = true
  }

  document.addEventListener("input", recordEdit, true)
  document.addEventListener("change", recordEdit, true)

  function afterModules(call) {
    return new Promise(function (resolve) {
      waiting.push(function () { resolve(call()) })
    })
  }

  function forward(global, method) {
    return function () {
      var args = Array.prototype.slice.call(arguments)
      return afterModules(function () { return window[global][method].apply(null, args) })
    }
  }

  function tracked(method, keyIndex) {
    var send = forward("CodeGymSaveStatus", method)
    return function () {
      var key = arguments[keyIndex]
      open[key] = (open[key] || 0) + 1
      function settle() { open[key] -= 1 }
      return send.apply(null, arguments).then(
        function (result) { settle(); return result },
        function (error) { settle(); throw error }
      )
    }
  }

  window.CodeGymRequest = {
    send: forward("CodeGymRequest", "send"),
    get: forward("CodeGymRequest", "get")
  }

  window.CodeGymSaveStatus = {
    save: tracked("save", 3),
    queue: tracked("queue", 0),
    queued: function (key) { return (open[key] || 0) > 0 },
    pending: function () {
      return Object.keys(open).some(function (key) { return open[key] > 0 }) ||
        probes.some(function (probe) { return probe() })
    },
    watch: function (probe) {
      probes.push(probe)
      afterModules(function () { return window.CodeGymSaveStatus.watch(probe) })
    },
    carry: forward("CodeGymSaveStatus", "carry"),
    report: forward("CodeGymSaveStatus", "report"),
    clear: forward("CodeGymSaveStatus", "clear")
  }

  var PULL_NOTE = "codegym:pull-refreshed"
  var PULL_HOLD = "pull-resuming"
  var PULL_HOLD_LIMIT_MS = 10000
  var pullHoldTimer = null

  // sessionStorage throws in some private modes; the pull's spinner is only polish.
  function withSessionStorage(use) {
    try { return use(window.sessionStorage) } catch (error) { return null }
  }

  function releasePullHold() {
    clearTimeout(pullHoldTimer)
    var held = document.documentElement.classList.contains(PULL_HOLD)
    document.documentElement.classList.remove(PULL_HOLD)
    return held
  }

  var pullNoted = withSessionStorage(function (storage) {
    var noted = storage.getItem(PULL_NOTE)
    storage.removeItem(PULL_NOTE)
    return noted
  })

  if (pullNoted) {
    document.documentElement.classList.add(PULL_HOLD)
    pullHoldTimer = setTimeout(releasePullHold, PULL_HOLD_LIMIT_MS)
  }

  window.CodeGymEarlyEdit = early
  window.CodeGymSaveStatus.watch(function () { return early.dirty })

  window.CodeGymBootstrap = {
    pullRefresh: {
      note: function () { withSessionStorage(function (storage) { storage.setItem(PULL_NOTE, "1") }) },
      release: releasePullHold
    },
    settleEarlyEdits: function () {
      document.removeEventListener("input", recordEdit, true)
      document.removeEventListener("change", recordEdit, true)
      early.dirty = false
    },
    flush: function () {
      var held = waiting
      waiting = []
      held.forEach(function (resume) { resume() })
    }
  }
})()
