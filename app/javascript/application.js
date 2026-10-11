import { application } from "controllers/application"
import "controllers"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

const CONNECT_TIMEOUT_MS = 10000
const CONNECT_POLL_MS = 10

function pageControllers() {
  return [ ...document.querySelectorAll("[data-controller]") ].flatMap((element) =>
    element.getAttribute("data-controller").split(/\s+/).filter(Boolean)
      .map((identifier) => [ element, identifier ]))
}

function everyControllerConnected() {
  return pageControllers().every(([ element, identifier ]) =>
    application.getControllerForElementAndIdentifier(element, identifier))
}

// A controller module that never arrives would otherwise hold the early edit pending for the rest of the page's life.
function controllersConnected() {
  const deadline = performance.now() + CONNECT_TIMEOUT_MS

  return new Promise((resolve) => {
    const poll = () => {
      if (everyControllerConnected() || performance.now() > deadline) resolve()
      else setTimeout(poll, CONNECT_POLL_MS)
    }

    poll()
  })
}

// The bootstrap publishes these two names at parse time, so the modules have to take the same names over.
window.CodeGymRequest = request
window.CodeGymSaveStatus = saveStatus
window.CodeGymBootstrap.flush()
// Stimulus imports each controller on its own, so start() resolving says nothing about any of them having connected.
window.CodeGymBootstrap.ready = application.start()
  .then(controllersConnected)
  .then(() => {
    window.CodeGymBootstrap.settleEarlyEdits()
    document.documentElement.dataset.jsReady = "true"
  })
