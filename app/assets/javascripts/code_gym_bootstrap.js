// Holds page-script calls made before the deferred modules run; docs/code-notes/app/assets/javascripts/code_gym_bootstrap.md
(function () {
  var waiting = []
  var probes = []
  var open = Object.create(null)

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

  window.CodeGymBootstrap = {
    flush: function () {
      var held = waiting
      waiting = []
      held.forEach(function (resume) { resume() })
    }
  }
})()
