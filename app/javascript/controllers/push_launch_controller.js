// Design notes: docs/code-notes/app/javascript/controllers/push_launch_controller.md
import { Controller } from "@hotwired/stimulus"
import push from "code_gym/push"

export default class extends Controller {
  static values = {
    vapidKey: String,
    registerPath: String,
    knownEndpoints: Array,
    registerFailedText: String
  }

  connect() {
    if (!push.supported()) return

    push.subscribeAndRegister(this.settings).catch(() => {
      // Deliberately silent: the Account page is where push state is shown and repaired.
    })
  }

  get settings() {
    return {
      vapidKey: this.vapidKeyValue,
      registerPath: this.registerPathValue,
      knownEndpoints: this.knownEndpointsValue,
      registerFailedText: this.registerFailedTextValue
    }
  }
}
