import { application } from "controllers/application"
import "controllers"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

// Aliases for the inline page scripts still to be converted; each goes once its last caller does.
window.CodeGymRequest = request
window.CodeGymSaveStatus = saveStatus
window.CodeGymBootstrap.flush()
// Controllers pick an edit made before they connected up as their own pending save, so release it only once they have.
application.start().then(() => window.CodeGymBootstrap.settleEarlyEdits())
