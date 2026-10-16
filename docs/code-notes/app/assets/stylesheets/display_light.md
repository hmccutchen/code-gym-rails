# app/assets/stylesheets/display_light.css

`docs/decisions/display-preferences.md` covers why these rules are unscoped: the `<link>`'s `media` attribute, from `DisplayPreferences#light_palette_media`, decides where the light palette applies. It also names `palette_contrast_spec`, which holds every text color here to WCAG AA.

## Selector overrides after `:root`

The file first restates the layout's `:root` variables, then overrides the layout's hardcoded dark colors selector by selector. Each override is prefixed with `html`. The extra specificity lets it beat the per-page `<style>` blocks, which come later in the document and would otherwise win.
