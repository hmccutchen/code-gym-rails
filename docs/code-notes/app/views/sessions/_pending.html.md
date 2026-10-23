# app/views/sessions/_pending.html.erb

## Code field's `aria-describedby`

The field takes focus on arrival, so a screen reader starts there and skips
the flash above it. Describing the field by that flash is what makes a
wrong-code error, or the code's expiry time, reach someone who cannot see it.
The partial renders only on the code page, where every alert is about the
code, so any alert is tied to the field.
