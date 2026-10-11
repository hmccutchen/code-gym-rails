import "controllers"
import request from "code_gym/request"
import saveStatus from "code_gym/save_status"

// Aliases for the inline page scripts still to be converted; each goes once its last caller does.
window.CodeGymRequest = request
window.CodeGymSaveStatus = saveStatus
