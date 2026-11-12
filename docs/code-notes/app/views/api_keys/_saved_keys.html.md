# app/views/api_keys/_saved_keys.html.erb

Takes no locals; it reads `current_user`. `edit.html.erb` renders it only
when the account has a stored key.

## Outside the Setup form

Each Remove button is its own form (`button_to` with `method: :delete`),
and a form cannot sit inside another, so the list comes after the Setup
form's closing tag and not beside the "Provider in use" choice, which
belongs to that form.

## Confirmation

Each form carries `loading_form_data(confirm_message:)`, the pattern the
account deletion button uses: the `loading-form` controller asks
`window.confirm` on submit and stops the submit when the person cancels.
The button is rendered disabled and the controller enables it when it
connects, so the form cannot post before the confirmation is in place.
The page needed no new script.

The message is chosen by `User#key_removal_outcome`, the value the
controller words its notice from after the removal, so the question and the
answer agree: a plain removal, a switch to the provider
`User#provider_after_removing` names, or the last key, where sets stop.

## Names

The button's text names the provider ("Remove Claude key"), so a screen
reader's list of buttons tells them apart. The list is labelled by its
heading. Providers are named by `AiProvider.label`, as the "Provider in
use" choice above names them. The key is never rendered.
