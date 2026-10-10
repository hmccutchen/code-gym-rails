# app/views/sessions/_pending.html.erb

## Code field's `aria-describedby`

The field takes focus on arrival, so a screen reader starts there and skips
the flash above it. Describing the field by that flash is what makes a
wrong-code error, or the code's expiry time, reach someone who cannot see it.
An alert from the "request a new code" form below says nothing about the code,
so only an alert from checking the code is tied to the field.
