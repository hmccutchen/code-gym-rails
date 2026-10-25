---
paths:
  - "app/views/layouts/**"
  - "app/views/pwa/**"
  - "app/views/history/**"
  - "app/views/shared/{_tab_bar,_pull_to_refresh,_push_script,_save_status_banner}.html.erb"
  - "app/views/accounts/**"
  - "app/views/api_keys/_display_preferences.html.erb"
  - "app/controllers/{history,push_subscriptions,accounts}_controller.rb"
  - "app/models/{display_preferences,push_subscription,code_highlight}.rb"
  - "app/services/push_delivery.rb"
  - "app/models/push_nudge_plan.rb"
  - "app/clients/web_push_credentials.rb"
  - "app/jobs/send_push_reminder_job.rb"
  - "app/helpers/{display_preferences,syntax_highlighting,public_file,navigation,push}_helper.rb"
  - "app/assets/**"
  - "app/javascript/controllers/{pull_to_refresh,push_enable,push_launch,display_preferences,code_lines,nav_menu,save_switch}_controller.js"
  - "app/javascript/code_gym/push.js"
  - "public/**"
  - "script/generate_icons.py"
  - "spec/**/*{pwa,push,nudges,display,palette,pull_to_refresh,history,highlight,icon,nav,focus_ring}*"
  - "app/jobs/generate_daily_exercises_job.rb"
  - "spec/**/*save_status*"
---

# Layout, display, the installed app and push

Each entry states what a change must not break. An entry that names a
`docs/decisions/` doc has its full reasoning, measurements and history there;
read it before changing that area.

- **Paginated history**: `/history` renders 10 submitted sessions per page via
  Pagy's offset paginator (`DailyResponse::HISTORY_PAGE_SIZE`). Pagy 43's API
  is a full rewrite — `Pagy::Method`, `pagy(:offset, …)`, and helper methods on
  the pagy object; the `Pagy::Backend`/`pagy_nav` API in most documentation is
  gone. An out-of-range page raises and redirects to the last real page rather
  than rendering the empty state to someone who has sessions. No redirect
  targets a particular entry, so nothing has to work out which page holds one.
- **Code blocks are highlighted on the server**
  (`docs/decisions/code-blocks-are-highlighted-on-the-server.md`): Every code
  block renders through `highlighted_code`, which calls `CodeHighlight.html`,
  the one place code becomes HTML; only Rouge's escaped output is marked safe.
  Output is cached per process in `CodeHighlight::CACHE`, never `Rails.cache`
  or a row. No page loads a browser highlighter, and the `code-lines`
  controller only decides wrapping.
- **Home-screen app** (`docs/decisions/home-screen-app.md`): Standalone iOS
  launch via `GET /manifest.json` and `apple-mobile-web-app-*` meta tags, a
  phone-width bottom tab bar, and pull-to-refresh. Link icons through
  `PublicFileHelper#versioned_public_path`; keep the maskable mark inside 40%
  of the size from center. Pull-to-refresh reads standalone mode from the
  layout's media query and waits for `CodeGymSaveStatus.pending()` to clear
  before reloading.
- **Display preferences** (`docs/decisions/display-preferences.md`): Theme,
  background pattern, text size, line spacing and reading font, saved through
  `PATCH /profile`. `DisplayPreferences` is the one list of choices, defaults
  first; storage is sparse jsonb, and `User` refuses values outside the
  lists. The background pattern is on by default on purpose, the one display
  change that needs no opt-in, so only an explicit `"off"` is stored. Every
  other default renders no `<html>` attribute or extra stylesheet.
  `#light_palette_media` drives the palette, logo and theme-color together. The reading font and spacing apply to prose, never
  code; `palette_contrast_spec` holds both palettes to WCAG AA; the nav
  collapses on one `@container` rule that `mobile_nav_menu_spec` guards.
- **Phone card styles**: `phone_cards.css` holds the card, full-width button
  and switch styles, plus the value row, segmented control, card tag,
  collapsible card, the range slider and the disabled switch row, for the
  Account and Settings pages; it loads on every
  page, so a new rule in it stays scoped to its own class. `.card-page` is
  the full-width card page (History), with the same phone gutter.
- **Desktop layout** (`docs/decisions/desktop-layout.md`): at 900px and wider
  a page that calls `wide_page` gets a centered column up to 1040px, built
  from `.container`'s gutter properties; a page widens only that way, and
  the `.container` rule itself is not edited. `desktop.css` holds nothing
  outside its one `@media (min-width: 900px)` block (`desktop_stylesheet_spec`),
  each rule scoped to a page class; a view's own `<style>` renders after it,
  so a desktop rule beats one of the view's with a more specific selector.
  A page's targets stay 44px at every width, with no `(pointer: fine)`
  relaxation; the top nav's links are 34px until #550.
- **Push reminders** (`docs/decisions/push-reminders.md`): Optional weekday
  ready and afternoon nudge notifications. Intent (`User#reminder_level`) and
  transport (`PushSubscription`) are separate: an endpoint can die without
  losing the user's answer, and turning reminders off or anonymizing clears
  both. Only submission stops the day's nudges; `PushNudgePlan` owns the
  window and `QUIET_PERIOD`, which must cover a full production tick
  (`push_nudge_plan_spec`), and `DailyResponse#submit_blocker` gates the copy.
  Both kinds are enqueued from `GenerateDailyExercisesJob`'s cron branch, with
  no cron entry of their own and none from the on-demand branch.
  `WebPushCredentials` decides whether push exists, endpoints stay on
  `ALLOWED_ENDPOINT_HOSTS`, and `Notification.requestPermission()` must be the
  click handler's first synchronous call. The nudges switch saves on change.
  Only Turn on posts `enroll: true`; launch and device repair never turn a
  level on, and registration and Turn off share the user-row lock.
