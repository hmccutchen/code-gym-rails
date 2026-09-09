# Glossary Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand "search the glossary" box to every section of the dashboard and history views, backed by a static curated Ruby hash of programming terms, resolved entirely client-side with zero network requests.

**Architecture:** A new `Glossary` module holds a frozen `TERMS` hash (term → one-sentence definition). The layout serializes that hash once into a `<script type="application/json">` tag; one delegated JS listener (mirroring the existing `gloss-term` tooltip script's pattern) reads it into a plain object and handles every `.glossary-search` box on the page. A new shared partial, `shared/_glossary_search`, renders the box's markup and is wired into all six section partials (nine render call sites total, across the active dashboard and every read-only/history render).

**Tech Stack:** Rails 8 views/ERB, vanilla JS (no Stimulus — see Global Constraints), RSpec request + system specs (Capybara + Playwright).

## Global Constraints

- No AI call at lookup time, ever — the whole feature must work with a dead session or an invalid/expired provider key.
- No changes to `GlossaryHelper`, `#glossary_wrap`, or any `problem_set[...]["glossary"]` data — that pre-generated inline feature is untouched and coexists with this one.
- No general-purpose dictionary gem/API integration.
- Storage is a plain Ruby constant (`app/models/glossary.rb`), not YAML — matches every existing curated vocabulary in this app (`RAILS_CONCEPTS`, `JS_CONCEPTS`, `ARCHITECTURE_CONCEPTS`, `SCENARIO_DOMAINS`), all of which are Ruby constants; there is no YAML-data precedent anywhere in this codebase.
- Naming is `Glossary` / "glossary search" in code and UI copy — kept distinct from `GlossaryHelper`'s `gloss-term` inline wrapping.
- Delivery is embedded JSON (`Glossary::TERMS.to_json` rendered once into the layout) searched entirely in JS — no controller, no route, no fetch call for a lookup.
- Lookup is exact match only after `strip`/`downcase` on both the input and the stored key — no fuzzy/substring suggestions.
- A miss renders a clearly-distinguished "isn't in the glossary yet" row — never a silent no-op, never a fallback to any live API.
- One box per section, appearing in both the active (unsubmitted) dashboard and every read-only render (dashboard's submitted state, every `/history` entry) — all six section partials.
- Results **stack** (append) per section, never replace — no dedupe against earlier searches in the same section, nothing persisted past reload.
- This app loads no Turbo/Stimulus JS (see `CLAUDE.md`) — all interactivity is inline `<script>` in the layout or partials, exactly like the existing `gloss-term` tooltip script and the autosave script in `_exercise.html.erb`.

---

## Task 1: `Glossary` model — curated term data + lookup

**Files:**
- Create: `app/models/glossary.rb`
- Test: `spec/models/glossary_spec.rb`

**Interfaces:**
- Produces: `Glossary::TERMS` — a frozen `Hash{String => String}`, every key already lowercase. `Glossary.lookup(term) -> String | nil` — normalizes `term` (`to_s.strip.downcase`) and returns the matching definition or `nil`. Task 2's JS embeds `Glossary::TERMS` directly (not `.lookup`, which is Ruby-only); Task 2's system spec asserts against `Glossary::TERMS["closure"]`.

- [ ] **Step 1: Write the failing spec**

Create `spec/models/glossary_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Glossary do
  describe ".lookup" do
    it "returns the definition for an exact match" do
      expect(Glossary.lookup("closure")).to eq(Glossary::TERMS["closure"])
    end

    it "matches case-insensitively" do
      expect(Glossary.lookup("Closure")).to eq(Glossary::TERMS["closure"])
    end

    it "strips surrounding whitespace before matching" do
      expect(Glossary.lookup("  closure  ")).to eq(Glossary::TERMS["closure"])
    end

    it "returns nil for a term not in the glossary" do
      expect(Glossary.lookup("not-a-real-term")).to be_nil
    end

    it "returns nil for blank input" do
      expect(Glossary.lookup("")).to be_nil
      expect(Glossary.lookup(nil)).to be_nil
    end
  end

  it "stores every key already lowercased, since .lookup only downcases its input" do
    Glossary::TERMS.keys.each do |key|
      expect(key).to eq(key.downcase)
    end
  end

  it "has no blank definitions" do
    expect(Glossary::TERMS.values).to all(be_present)
  end
end
```

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/models/glossary_spec.rb`
Expected: FAIL — `uninitialized constant Glossary`

- [ ] **Step 3: Create `app/models/glossary.rb`**

```ruby
# Static, hand-curated glossary of programming terms, searched on demand via
# the "Search the glossary" box (shared/_glossary_search, wired up by the
# layout's glossary-search script) — separate from AiService's per-section
# pre-generated glossary rendered inline by GlossaryHelper. Drafted once with
# AI assistance, then hand-reviewed; nothing touches this file automatically
# again. Extend it by adding one line — keys must already be lowercase, since
# .lookup only downcases and strips its INPUT, never the stored keys.
module Glossary
  TERMS = {
    "abstraction" => "Hiding the messy details behind a simpler interface so callers only need to know what something does, not how.",
    "acid" => "Atomicity, Consistency, Isolation, Durability — the four guarantees a database transaction makes about behaving as a single, safe unit.",
    "adapter pattern" => "A wrapper that translates one interface into another so two incompatible pieces of code can work together.",
    "api versioning" => "Marking breaking changes to an API (e.g. /v1, /v2) so existing clients keep working while new ones adopt the new shape.",
    "arrow function" => "A shorthand JS function syntax that doesn't rebind `this`, inheriting it from the surrounding scope instead.",
    "array mutation" => "Changing an array in place (push, splice, sort) rather than creating a new one — can surprise code that expected the original to stay untouched.",
    "async/await" => "Syntax for writing asynchronous, promise-based code that reads top-to-bottom like synchronous code.",
    "authorization" => "Checking whether an already-identified user is allowed to perform a specific action, distinct from authentication (who they are).",
    "background job" => "Work queued to run outside the request/response cycle, so a slow task doesn't make the user wait for it.",
    "big o notation" => "A way to describe how an algorithm's time or memory use grows as its input grows, ignoring constant factors.",
    "blue-green deployment" => "Running two identical production environments and switching traffic from one to the other, so a release has an instant rollback path.",
    "build vs buy" => "The decision between building a capability in-house versus adopting an existing tool or vendor for it.",
    "bundler" => "A tool (e.g. esbuild, webpack) that combines many JavaScript modules into the smaller set of files a browser actually loads.",
    "cache invalidation" => "Deciding when cached data is stale and must be refreshed or removed — notoriously one of the two hard problems in computer science.",
    "caching" => "Storing the result of expensive work so a later request can reuse it instead of redoing the work.",
    "caching strategy" => "The set of decisions about what to cache, for how long, and how it gets invalidated, matched to how fresh the data needs to be.",
    "callback" => "A function passed into another function to be run later, often once some asynchronous work finishes.",
    "callback hell" => "Deeply nested callbacks that make asynchronous code hard to read and reason about, usually solved with promises or async/await.",
    "callbacks vs service objects" => "Choosing between a model lifecycle hook (before_save, after_create) and a standalone class to hold business logic that reaches beyond one model.",
    "canary release" => "Rolling a change out to a small slice of traffic first, so a bad deploy affects a few users instead of everyone.",
    "circuit breaker" => "A safeguard that stops calling a failing dependency for a while after repeated failures, instead of retrying into a wall.",
    "closure" => "A function that remembers the variables from where it was defined, even after that outer scope has finished running.",
    "closures in loops" => "A classic bug where every closure created inside a loop captures the same variable binding, not a snapshot of its value at that iteration.",
    "code splitting" => "Breaking a JS bundle into smaller chunks that load only when needed, instead of one large file up front.",
    "composite index" => "A database index built across multiple columns together, useful when queries filter or sort by that same combination.",
    "composition over inheritance" => "Preferring to build behavior by combining small, focused objects rather than by extending a class hierarchy.",
    "concern" => "A module mixed into a Rails model or controller to share behavior across classes without deep inheritance.",
    "context api" => "React's built-in way to pass data down a component tree without threading props through every intermediate level.",
    "controlled component" => "A form input whose value is driven entirely by React state, with every change going through a handler.",
    "coupling and cohesion" => "How entangled separate parts of a system are with each other (coupling) versus how focused a single part is on one responsibility (cohesion).",
    "cron" => "A schedule for running a job automatically at fixed times or intervals, without a person triggering it.",
    "csrf" => "Cross-Site Request Forgery — an attack that tricks a logged-in user's browser into submitting a request they didn't intend, defended against with per-session tokens.",
    "currying" => "Transforming a function that takes multiple arguments into a sequence of functions that each take one argument.",
    "data consistency tradeoffs" => "The tension between keeping data always correct everywhere (strong consistency) and accepting brief staleness for speed and availability (eventual consistency).",
    "data ownership" => "Which single service or team is the authoritative source of truth for a piece of data, so other consumers read a copy rather than mutate it directly.",
    "deadlock" => "Two or more processes each waiting on a resource the other holds, so neither can ever proceed.",
    "debouncing" => "Delaying a function's execution until a burst of calls has paused for a set time, so only the last one actually runs.",
    "decorator pattern" => "Wrapping an object to add behavior to it without changing its own class.",
    "denormalization" => "Duplicating data across tables to speed up reads, at the cost of having to keep the copies in sync on writes.",
    "dependency injection" => "Supplying an object's dependencies from outside rather than having it construct them itself, making the object easier to test and swap.",
    "destructuring" => "JS/TS syntax for unpacking values from an array or object into individual variables in one statement.",
    "discriminated union" => "A TypeScript union type where each variant carries a common tag field, letting the compiler narrow which shape you're dealing with.",
    "dry" => "Don't Repeat Yourself — every piece of knowledge should have a single, unambiguous representation in a system.",
    "duck typing" => "Treating an object as usable based on what methods it responds to, not on its declared class or type.",
    "eager loading" => "Fetching associated records up front in one query, avoiding the N+1 problem of fetching them one at a time later.",
    "enum" => "A type restricted to a fixed set of named values, used to make an otherwise-stringly-typed field self-documenting and exhaustive.",
    "error handling" => "Deciding what a program does when something goes wrong — rescue, retry, log, or surface — rather than letting a failure propagate unchecked.",
    "event-driven vs request-response" => "Choosing between systems that react to published events asynchronously versus ones where a caller waits synchronously for a direct reply.",
    "event emitter" => "An object other code can subscribe to, which then broadcasts events to every listener when something happens.",
    "event loop" => "The mechanism that lets a single-threaded language like JS handle asynchronous work by processing tasks and callbacks from a queue.",
    "event loop blocking" => "Long-running synchronous code that hogs the event loop, freezing everything else — timers, I/O, rendering — until it finishes.",
    "exponential backoff" => "Waiting progressively longer between retries after a failure, so a struggling dependency isn't hammered with immediate retries.",
    "failure mode design" => "Deliberately planning how a system behaves when a dependency fails, instead of only designing for the happy path.",
    "feature flag" => "A toggle that turns a piece of functionality on or off without a deploy, often used to roll changes out gradually.",
    "first-class function" => "A function that can be assigned to a variable, passed as an argument, and returned from another function, like any other value.",
    "foreign key" => "A column that references another table's primary key, used by the database to enforce that the referenced row actually exists.",
    "garbage collection" => "Automatic reclamation of memory no longer reachable by the running program, so the developer doesn't manually free it.",
    "generics" => "Writing a function or type that works over a range of types while still preserving type information, instead of using `any`.",
    "hoisting" => "JS's behavior of moving variable and function declarations to the top of their scope before code runs — though only the declaration, not the assignment.",
    "hooks dependencies" => "The array passed to a React hook (useEffect, useMemo) that tells it which values to watch, re-running the hook when any of them change.",
    "horizontal scaling" => "Handling more load by adding more machines running the same code, as opposed to making one machine more powerful.",
    "idempotency" => "A property where performing the same operation multiple times has the same effect as performing it once.",
    "idempotency at scale" => "Designing a distributed operation so a retry after a network failure never double-applies its effect, even without knowing whether the first attempt actually landed.",
    "immutability" => "Data that can't be changed after it's created — any 'change' produces a new value instead of mutating the original.",
    "indexing" => "A database structure that speeds up lookups on a column at the cost of extra storage and slower writes.",
    "inheritance" => "One class acquiring the behavior and structure of another (its parent), typically extending or overriding it.",
    "insecure client storage" => "Keeping sensitive data (tokens, secrets) in localStorage or a cookie without the protections that make it safe from theft, e.g. via XSS.",
    "inversion of control" => "Framework or container code calling into your code, rather than your code driving the call — the framework decides when your code runs.",
    "jwt" => "JSON Web Token — a signed, self-contained token that carries claims (like user identity) a server can verify without a database lookup.",
    "lazy loading" => "Deferring the loading of data or code until it's actually needed, rather than up front.",
    "load balancer" => "A layer that distributes incoming requests across multiple servers so no single one is overwhelmed.",
    "mass assignment" => "Setting many model attributes at once from a hash of params — dangerous unless the allowed attributes are explicitly restricted.",
    "memoization" => "Caching a function's return value for a given input so a later call with the same input skips the work.",
    "memory leak" => "Memory that's no longer needed but never gets freed, because something still holds a reference to it — often an event listener that was never removed.",
    "metaprogramming" => "Code that writes or modifies code at runtime, e.g. dynamically defining methods rather than writing them out by hand.",
    "method_missing" => "A Ruby hook that intercepts calls to methods that don't exist, letting an object handle them dynamically instead of raising immediately.",
    "microtask queue" => "The higher-priority JS task queue (promise callbacks, queueMicrotask) that always drains fully before the next macrotask (setTimeout, I/O) runs.",
    "middleware" => "Code that sits in the request/response pipeline and can inspect, modify, or short-circuit a request before it reaches the app, or a response before it leaves.",
    "migration" => "A versioned, reversible script that changes a database schema, so schema changes are tracked and reproducible across environments.",
    "mixin" => "A module of reusable methods 'mixed into' a class, giving it that behavior without inheriting from another class.",
    "mock" => "A test double that stands in for a real object and asserts it was called in the expected way.",
    "mutex" => "A lock that lets only one thread access a shared resource at a time, preventing concurrent modification.",
    "n+1" => "A performance bug where fetching a list triggers one query per item's association, instead of one query for the whole list up front.",
    "n_plus_one" => "A performance bug where fetching a list triggers one query per item's association, instead of one query for the whole list up front.",
    "normalization" => "Structuring database tables to minimize duplicated data, so each fact is stored in exactly one place.",
    "nullish coalescing" => "The `??` operator, which falls back to a default only when the left side is null or undefined — unlike `||`, it doesn't treat 0 or '' as missing.",
    "observability tradeoffs" => "The balance between how much logging/metrics/tracing a system emits and the cost, performance overhead, and noise that comes with it.",
    "observer pattern" => "Objects (observers) subscribing to notifications from another object (the subject) whenever its state changes.",
    "optimistic locking" => "Detecting a conflicting concurrent update by checking a version number at save time, rather than locking the row for the whole transaction.",
    "optional chaining" => "The `?.` operator, which short-circuits to undefined instead of throwing when accessing a property on something that might be null or undefined.",
    "orm" => "Object-Relational Mapping — a library that lets you work with database rows as objects instead of writing raw SQL.",
    "over-mocking" => "Stubbing out so much of the system under test that the test verifies the mocks were called correctly rather than that the real behavior works.",
    "pessimistic locking" => "Locking a row for the duration of a transaction so no other transaction can touch it, trading concurrency for certainty.",
    "policy object" => "A class that centralizes an authorization decision (can this user do this?) instead of scattering permission checks through controllers.",
    "polymorphism" => "Different objects responding to the same method call in ways specific to their own type.",
    "promise" => "An object representing the eventual result (or failure) of an asynchronous operation, which callbacks or await can attach to.",
    "promise chaining" => "Attaching a sequence of `.then()` calls to run asynchronous steps in order, each receiving the previous step's result.",
    "props drilling" => "Passing a prop down through several React components that don't use it themselves, just to reach a deeply nested child.",
    "prototype chain" => "The lookup path JS follows when a property isn't found directly on an object, walking up through the objects it inherits from.",
    "pub/sub" => "A messaging pattern where publishers emit events without knowing who's listening, and subscribers receive events without knowing who sent them.",
    "pure function" => "A function whose output depends only on its inputs and that causes no observable side effects, making it predictable and easy to test.",
    "query object" => "A class that encapsulates a specific, reusable database query, keeping complex query logic out of the model.",
    "race condition" => "A bug where the outcome depends on the unpredictable timing of concurrent operations, e.g. two requests reading-then-writing the same value.",
    "rate limiting" => "Capping how many requests a client can make in a given time window, to protect a system from overload or abuse.",
    "recursion" => "A function that calls itself to solve a smaller version of the same problem, until it reaches a base case.",
    "reconciliation" => "React's algorithm for comparing a new virtual DOM tree to the previous one and updating only what actually changed in the real DOM.",
    "referential integrity" => "The database guarantee that a foreign key always points to a row that actually exists.",
    "replication" => "Keeping copies of a database on multiple servers, for redundancy and to spread out read load.",
    "retry logic" => "Automatically re-attempting a failed operation, usually with backoff, instead of surfacing the failure immediately.",
    "rollback" => "Reversing a database migration back to its previous schema state.",
    "scaling bottlenecks" => "The specific components (a database, a single-threaded service) that stop a system from handling more load, even after adding more of everything else.",
    "scope chaining" => "Combining multiple ActiveRecord scopes into one query by calling them in sequence.",
    "seed data" => "Pre-populated records loaded into a database, typically for local development or a fresh environment.",
    "service boundaries" => "The lines drawn between separate services in a system, defining what each one owns and how they're allowed to talk to each other.",
    "service object" => "A plain class that holds a single business operation, used when logic doesn't naturally belong on a model or in a controller.",
    "sharding" => "Splitting a dataset across multiple databases, each holding a subset of the rows, to scale beyond what one database can hold.",
    "side effect" => "Any change a function makes beyond returning a value — writing to a variable outside itself, doing I/O, mutating an argument.",
    "single responsibility principle" => "The idea that a class or module should have exactly one reason to change.",
    "singleton pattern" => "Ensuring a class has exactly one instance, with a single global point of access to it.",
    "spread operator" => "The `...` syntax for expanding an array or object's elements/properties into another array, object, or argument list.",
    "sql injection" => "An attack where untrusted input is concatenated directly into a SQL query, letting an attacker run arbitrary SQL — prevented by parameterized queries.",
    "stack vs heap" => "Two regions of memory: the stack holds fixed-size, short-lived data tied to function calls; the heap holds dynamically allocated data that outlives a single call.",
    "state lifting" => "Moving state up to the nearest common ancestor component so multiple children can share and stay in sync with it.",
    "state management" => "The approach an app uses to store and update shared data (local component state, context, or a dedicated store).",
    "static site generation" => "Rendering pages to static HTML at build time rather than on every request, trading flexibility for speed and simplicity.",
    "strategy pattern" => "Encapsulating interchangeable algorithms behind a common interface, so the caller can swap which one runs without changing its own code.",
    "strict mode" => "An opt-in JS mode that turns silent mistakes (like assigning to an undeclared variable) into thrown errors.",
    "stub" => "A test double that returns a canned response when called, without asserting how it was called.",
    "temporal dead zone" => "The span between entering a scope and a `let`/`const` variable's declaration line, during which referencing it throws instead of returning undefined.",
    "testing implementation not behavior" => "Writing a test that breaks when internal code is refactored even though external behavior didn't change — a sign the test is coupled to how, not what.",
    "this binding" => "How JS determines what `this` refers to inside a function, which depends on how the function is called, not where it's defined (except for arrow functions).",
    "thread pool" => "A fixed set of reusable worker threads that pick up queued work, avoiding the cost of creating a new thread per task.",
    "thread safety" => "Code that behaves correctly when accessed by multiple threads at once, without needing external synchronization.",
    "throttling" => "Limiting a function to run at most once per fixed interval, no matter how often it's triggered.",
    "transaction" => "A group of database operations that all succeed together or all roll back together, so the database is never left half-updated.",
    "transaction isolation level" => "How much one in-progress transaction can see of another's uncommitted changes, trading consistency guarantees for concurrency.",
    "tree shaking" => "A bundler optimization that removes exported code nobody actually imports, shrinking the final bundle.",
    "two-way binding" => "A form pattern where a UI input both displays and updates a piece of state automatically, without a separate change handler.",
    "type guard" => "A runtime check (like `typeof` or `instanceof`) that lets TypeScript narrow a variable to a more specific type within a block.",
    "type inference" => "A type system figuring out a value's type from context, without the developer writing an explicit annotation.",
    "union type" => "A TypeScript type that can be one of several specified types, e.g. `string | number`.",
    "unidirectional data flow" => "Data moving in one direction through an app (e.g. parent to child, store to component), making state changes easier to trace.",
    "virtual dom" => "An in-memory representation of the UI that a library like React diffs against the previous version to compute the minimal real DOM update.",
    "webhook" => "An HTTP callback a service sends to a URL you provide when an event happens, instead of you polling for it.",
    "xss" => "Cross-Site Scripting — an attack where untrusted input is rendered as executable script in another user's browser, prevented by escaping output.",
    "yagni" => "You Aren't Gonna Need It — a reminder not to build functionality speculatively, before there's an actual requirement for it."
  }.freeze

  def self.lookup(term)
    TERMS[term.to_s.strip.downcase]
  end
end
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/models/glossary_spec.rb`
Expected: PASS (7 examples, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add app/models/glossary.rb spec/models/glossary_spec.rb
git commit -m "$(cat <<'EOF'
Add Glossary model with curated term data

Static, hand-curated hash of ~145 programming terms, drafted once and
hand-reviewed — no AI touches this file automatically again. Backs the
on-demand glossary search feature (later tasks), separate from
GlossaryHelper's pre-generated inline glossary.
EOF
)"
```

---

## Task 2: Layout wiring + `shared/_glossary_search` partial + first section

**Files:**
- Modify: `app/views/layouts/application.html.erb`
- Create: `app/views/shared/_glossary_search.html.erb`
- Modify: `app/views/dashboard/_exercise.html.erb`
- Test: `spec/system/glossary_search_spec.rb`

**Interfaces:**
- Consumes: `Glossary::TERMS` (Task 1) — embedded as JSON in the layout.
- Produces: partial `shared/glossary_search`, local `field:` (a `String` section identifier, e.g. `"code_review"` — used only for the box's `data-field` attribute, read by tests/debugging, not by the search script itself). Rendered markup contract: a `div[data-glossary-search][data-field="<field>"]` containing `input[type=text]`, `button`, and `ul.glossary-results` — Task 3 renders this same partial with the same `field:` signature into the remaining eight call sites.

- [ ] **Step 1: Write the failing system spec**

Create `spec/system/glossary_search_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Glossary search on the dashboard", type: :system do
  it "looks up a known term, flags an unknown term, and stacks results in one section" do
    user = create_fake_provider_user

    travel_to(a_weekday) do
      DailyExercise.create!(
        user: user, date: Date.current, language: "ruby_rails", generated_at: Time.current,
        problem_set: FakeService::EXERCISE_PROBLEM_SET.deep_dup
      )
      visit_as(user)
      expect(page).to have_content(/Code Review/i, wait: 10)

      box = find("[data-glossary-search][data-field='code_review']")

      box.find("input[type='text']").fill_in(with: "closure")
      box.find("button").click
      expect(box).to have_css(".glossary-results li", count: 1)
      expect(box).to have_content("closure: #{Glossary::TERMS['closure']}")

      box.find("input[type='text']").fill_in(with: "not-a-real-term")
      box.find("button").click
      expect(box).to have_css(".glossary-results li", count: 2)
      expect(box).to have_css(".glossary-results li.glossary-miss",
        text: /"not-a-real-term" isn't in the glossary yet/)
    end
  end
end
```

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/system/glossary_search_spec.rb`
Expected: FAIL — Capybara cannot find `[data-glossary-search][data-field='code_review']`

- [ ] **Step 3: Create `app/views/shared/_glossary_search.html.erb`**

```erb
<%# On-demand static glossary lookup — distinct from GlossaryHelper's
    pre-generated inline gloss-term spans. Searches Glossary::TERMS, embedded
    once in the layout as JSON and read entirely client-side by the layout's
    glossary-search script; this partial only renders the box's markup.
    Local: field (a section identifier, e.g. "code_review") — used only to
    label the box's data-field attribute for tests/debugging; the search
    script itself walks the DOM via closest(), not this attribute. %>
<div class="glossary-search" data-glossary-search data-field="<%= field %>">
  <div class="glossary-search-row">
    <input type="text" placeholder="Search the glossary…" aria-label="Search the glossary">
    <button type="button" class="btn btn-ghost btn-sm">Search</button>
  </div>
  <ul class="glossary-results" aria-live="polite"></ul>
</div>
```

- [ ] **Step 4: Add glossary-search CSS to the layout**

In `app/views/layouts/application.html.erb`, find:

```css
    .gloss-term.gloss-open::after, .gloss-term:focus-visible::after { display: block; }
    .gloss-term:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

    .submit-row { display: flex; gap: 1rem; align-items: center; margin-top: 1.5rem; }
```

Replace with:

```css
    .gloss-term.gloss-open::after, .gloss-term:focus-visible::after { display: block; }
    .gloss-term:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

    .glossary-search { margin-top: 1rem; padding-top: .85rem; border-top: 1px dashed var(--border); }
    .glossary-search-row { display: flex; gap: .5rem; }
    .glossary-search input[type="text"] { flex: 1; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: .45rem .65rem; color: var(--text); font-size: .85rem; }
    .glossary-results { list-style: none; margin: .6rem 0 0; padding: 0; font-size: .85rem; }
    .glossary-results li { padding: .4rem 0; border-bottom: 1px solid var(--border); line-height: 1.5; }
    .glossary-results li:last-child { border-bottom: none; }
    .glossary-results li strong { color: var(--text); }
    .glossary-results li.glossary-miss { color: var(--muted); font-style: italic; }

    .submit-row { display: flex; gap: 1rem; align-items: center; margin-top: 1.5rem; }
```

- [ ] **Step 5: Add the embedded glossary JSON and delegated search script to the layout**

In `app/views/layouts/application.html.erb`, find the end of the gloss-term tooltip script block:

```erb
      window.addEventListener("resize", () => {
        const open = document.querySelector(".gloss-term.gloss-open");
        if (open) positionPanel(open);
      });
    })();
  </script>
  <%# Per-page scripts that would otherwise be duplicated once per rendered
```

Replace with:

```erb
      window.addEventListener("resize", () => {
        const open = document.querySelector(".gloss-term.gloss-open");
        if (open) positionPanel(open);
      });
    })();
  </script>
  <script type="application/json" id="glossary-data"><%= raw json_escape(Glossary::TERMS.to_json) %></script>
  <%# Glossary search: on-demand lookup against the static Glossary::TERMS
      hash embedded above as JSON — entirely client-side, so it keeps working
      even with a dead session or an invalid/expired provider key. Separate
      from the gloss-term tooltip script above, which only renders AI-picked
      terms inline; this searches ANY term a user types. One delegated
      listener handles every .glossary-search box on the page, regardless of
      which section partial rendered it — same pattern as the tooltip script. %>
  <script>
    (() => {
      const dataEl = document.getElementById("glossary-data");
      const terms = Object.create(null);
      if (dataEl) {
        const parsed = JSON.parse(dataEl.textContent);
        Object.keys(parsed).forEach((key) => { terms[key] = parsed[key]; });
      }

      const runSearch = (box) => {
        const input = box.querySelector("input[type='text']");
        const list = box.querySelector(".glossary-results");
        const raw = input.value.trim();
        if (!raw) return;

        const definition = terms[raw.toLowerCase()];
        const li = document.createElement("li");
        if (definition) {
          const strong = document.createElement("strong");
          strong.textContent = `${raw}: `;
          li.append(strong, document.createTextNode(definition));
        } else {
          li.className = "glossary-miss";
          li.textContent = `"${raw}" isn't in the glossary yet.`;
        }
        list.appendChild(li);
        input.value = "";
        input.focus();
      };

      document.addEventListener("click", (event) => {
        const button = event.target.closest("[data-glossary-search] button");
        if (!button) return;
        runSearch(button.closest("[data-glossary-search]"));
      });

      document.addEventListener("keydown", (event) => {
        if (event.key !== "Enter") return;
        const input = event.target.closest("[data-glossary-search] input[type='text']");
        if (!input) return;
        event.preventDefault();
        runSearch(input.closest("[data-glossary-search]"));
      });
    })();
  </script>
  <%# Per-page scripts that would otherwise be duplicated once per rendered
```

- [ ] **Step 6: Wire the partial into the code_review section**

In `app/views/dashboard/_exercise.html.erb`, find:

```erb
      <div class="rating-row" data-rating-for="code_review">
        <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
          <button type="button" class="rating-btn<%= " active" if response.self_rating_for("code_review") == value %>" data-rating-for="code_review" data-rating="<%= value %>"><%= label.upcase_first %></button>
        <% end %>
      </div>
    </div>

    <% pat = exercise.pattern %>
```

Replace with:

```erb
      <div class="rating-row" data-rating-for="code_review">
        <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
          <button type="button" class="rating-btn<%= " active" if response.self_rating_for("code_review") == value %>" data-rating-for="code_review" data-rating="<%= value %>"><%= label.upcase_first %></button>
        <% end %>
      </div>
      <%= render "shared/glossary_search", field: "code_review" %>
    </div>

    <% pat = exercise.pattern %>
```

- [ ] **Step 7: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/system/glossary_search_spec.rb`
Expected: PASS (1 example, 0 failures)

- [ ] **Step 8: Commit**

```bash
git add app/views/layouts/application.html.erb app/views/shared/_glossary_search.html.erb app/views/dashboard/_exercise.html.erb spec/system/glossary_search_spec.rb
git commit -m "$(cat <<'EOF'
Add glossary search box: layout wiring + code_review section

Embeds Glossary::TERMS as JSON in the layout and adds a delegated JS
listener that searches it client-side with zero network requests —
one box per section, wired into code_review first. Remaining sections
follow in the next commit.
EOF
)"
```

---

## Task 3: Wire the remaining eight call sites

**Files:**
- Modify: `app/views/dashboard/_exercise.html.erb` (pattern + challenge sections)
- Modify: `app/views/responses/_answered_sections.html.erb` (code_review, pattern, challenge sections)
- Modify: `app/views/responses/_architecture_section.html.erb`
- Modify: `app/views/responses/_security_review_section.html.erb`
- Modify: `app/views/responses/_parsons_problem_section.html.erb`
- Test: `spec/requests/glossary_search_placement_spec.rb`

**Interfaces:**
- Consumes: partial `shared/glossary_search`, local `field:` (Task 2).

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/glossary_search_placement_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Glossary search boxes across every section", type: :request do
  let(:user) { create_user_with_key }
  before { login_as(user) }

  it "renders a box for code_review, pattern, and architecture on the unsubmitted dashboard" do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "architecture" => { "title" => "A", "question" => "q" }
      }
    )
    get root_path

    expect(response.body).to include('data-glossary-search data-field="code_review"')
    expect(response.body).to include('data-glossary-search data-field="pattern"')
    expect(response.body).to include('data-glossary-search data-field="architecture"')
  end

  it "renders a box for challenge on the unsubmitted dashboard when there is no architecture/security_review/parsons_problem section" do
    DailyExercise.create!(
      user: user, date: Date.current, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "challenge" => { "title" => "C", "question" => "q" }
      }
    )
    get root_path

    expect(response.body).to include('data-glossary-search data-field="challenge"')
  end

  it "renders a box in every section of a submitted day, including security_review and parsons_problem" do
    exercise_a = DailyExercise.create!(
      user: user, date: 2.days.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "security_review" => { "title" => "S", "question" => "q", "snippet" => "s" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise_a, date: exercise_a.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "security_review" => "c" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "security_review" => "right_level" }
    )

    exercise_b = DailyExercise.create!(
      user: user, date: 1.day.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "parsons_problem" => { "title" => "PP", "question" => "q", "blocks" => [ "a", "b" ], "display_order" => [ 0, 1 ] }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise_b, date: exercise_b.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "parsons_problem" => "order:0,1" },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "parsons_problem" => "right_level" }
    )

    get history_path

    expect(response.body).to include('data-glossary-search data-field="security_review"')
    expect(response.body).to include('data-glossary-search data-field="parsons_problem"')
    expect(response.body.scan('data-glossary-search data-field="code_review"').size).to eq(2)
    expect(response.body.scan('data-glossary-search data-field="pattern"').size).to eq(2)
  end

  it "renders a box for challenge on a submitted day too" do
    exercise = DailyExercise.create!(
      user: user, date: 3.days.ago.to_date, generated_at: Time.current,
      problem_set: {
        "code_review" => { "question" => "q", "snippet" => "s" },
        "pattern" => { "title" => "P", "question" => "q" },
        "challenge" => { "title" => "C", "question" => "q" }
      }
    )
    DailyResponse.create!(
      user: user, daily_exercise: exercise, date: exercise.date, submitted_at: Time.current,
      answers: { "code_review" => "a" * 20, "pattern" => "b" * 20, "challenge" => "c" * 20 },
      section_ratings: { "code_review" => "right_level", "pattern" => "right_level", "challenge" => "right_level" }
    )

    get history_path

    expect(response.body).to include('data-glossary-search data-field="challenge"')
  end
end
```

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/requests/glossary_search_placement_spec.rb`
Expected: FAIL — first example's `data-field="pattern"`/`"architecture"` assertions fail (only `code_review` is wired so far); other examples fail entirely (`challenge`/`security_review`/`parsons_problem` boxes don't exist yet).

- [ ] **Step 3: Wire the pattern section in `_exercise.html.erb`**

Find:

```erb
      <div class="rating-row" data-rating-for="pattern">
        <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
          <button type="button" class="rating-btn<%= " active" if response.self_rating_for("pattern") == value %>" data-rating-for="pattern" data-rating="<%= value %>"><%= label.upcase_first %></button>
        <% end %>
      </div>
    </div>

    <% if (arch = exercise.architecture) %>
```

Replace with:

```erb
      <div class="rating-row" data-rating-for="pattern">
        <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
          <button type="button" class="rating-btn<%= " active" if response.self_rating_for("pattern") == value %>" data-rating-for="pattern" data-rating="<%= value %>"><%= label.upcase_first %></button>
        <% end %>
      </div>
      <%= render "shared/glossary_search", field: "pattern" %>
    </div>

    <% if (arch = exercise.architecture) %>
```

- [ ] **Step 4: Wire the challenge section in `_exercise.html.erb`**

Find:

```erb
        <div class="rating-row" data-rating-for="challenge">
          <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
            <button type="button" class="rating-btn<%= " active" if response.self_rating_for("challenge") == value %>" data-rating-for="challenge" data-rating="<%= value %>"><%= label.upcase_first %></button>
          <% end %>
        </div>
      </div>
    <% end %>
```

Replace with:

```erb
        <div class="rating-row" data-rating-for="challenge">
          <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
            <button type="button" class="rating-btn<%= " active" if response.self_rating_for("challenge") == value %>" data-rating-for="challenge" data-rating="<%= value %>"><%= label.upcase_first %></button>
          <% end %>
        </div>
        <%= render "shared/glossary_search", field: "challenge" %>
      </div>
    <% end %>
```

- [ ] **Step 5: Wire the code_review and pattern sections in `_answered_sections.html.erb`**

Find:

```erb
  <div class="answer-display"><%= response.answers["code_review"].presence || "(skipped)" %></div>
</div>
<% end %>

<% if (pat = exercise.pattern) %>
```

Replace with:

```erb
  <div class="answer-display"><%= response.answers["code_review"].presence || "(skipped)" %></div>
  <%= render "shared/glossary_search", field: "code_review" %>
</div>
<% end %>

<% if (pat = exercise.pattern) %>
```

Then find:

```erb
  <div class="answer-display"><%= response.answers["pattern"].presence || "(skipped)" %></div>
</div>
<% end %>

<% if (arch = exercise.architecture) %>
```

Replace with:

```erb
  <div class="answer-display"><%= response.answers["pattern"].presence || "(skipped)" %></div>
  <%= render "shared/glossary_search", field: "pattern" %>
</div>
<% end %>

<% if (arch = exercise.architecture) %>
```

- [ ] **Step 6: Wire the challenge section in `_answered_sections.html.erb`**

Find:

```erb
    <div class="answer-display"><%= response.answers["challenge"].presence || "(skipped)" %></div>
  </div>
<% end %>
```

Replace with:

```erb
    <div class="answer-display"><%= response.answers["challenge"].presence || "(skipped)" %></div>
    <%= render "shared/glossary_search", field: "challenge" %>
  </div>
<% end %>
```

- [ ] **Step 7: Wire `_architecture_section.html.erb`**

Find:

```erb
  <% end %>
</div>
<% if arch.dig("reference", "diagram").present? && !@architecture_diagram_script_emitted %>
```

Replace with:

```erb
  <% end %>
  <%= render "shared/glossary_search", field: "architecture" %>
</div>
<% if arch.dig("reference", "diagram").present? && !@architecture_diagram_script_emitted %>
```

- [ ] **Step 8: Wire `_security_review_section.html.erb`**

Find:

```erb
    <div class="rating-row" data-rating-for="security_review">
      <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
        <button type="button" class="rating-btn<%= " active" if response.self_rating_for("security_review") == value %>" data-rating-for="security_review" data-rating="<%= value %>"><%= label.upcase_first %></button>
      <% end %>
    </div>
  <% end %>
</div>
```

Replace with:

```erb
    <div class="rating-row" data-rating-for="security_review">
      <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
        <button type="button" class="rating-btn<%= " active" if response.self_rating_for("security_review") == value %>" data-rating-for="security_review" data-rating="<%= value %>"><%= label.upcase_first %></button>
      <% end %>
    </div>
  <% end %>
  <%= render "shared/glossary_search", field: "security_review" %>
</div>
```

- [ ] **Step 9: Wire `_parsons_problem_section.html.erb`**

Find:

```erb
    <div class="rating-row" data-rating-for="parsons_problem">
      <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
        <button type="button" class="rating-btn<%= " active" if response.self_rating_for("parsons_problem") == value %>" data-rating-for="parsons_problem" data-rating="<%= value %>"><%= label.upcase_first %></button>
      <% end %>
    </div>
  <% end %>
</div>
<% unless submitted || @parsons_script_emitted %>
```

Replace with:

```erb
    <div class="rating-row" data-rating-for="parsons_problem">
      <% DailyResponse::SELF_RATING_LABELS.each do |value, label| %>
        <button type="button" class="rating-btn<%= " active" if response.self_rating_for("parsons_problem") == value %>" data-rating-for="parsons_problem" data-rating="<%= value %>"><%= label.upcase_first %></button>
      <% end %>
    </div>
  <% end %>
  <%= render "shared/glossary_search", field: "parsons_problem" %>
</div>
<% unless submitted || @parsons_script_emitted %>
```

- [ ] **Step 10: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/requests/glossary_search_placement_spec.rb`
Expected: PASS (4 examples, 0 failures)

- [ ] **Step 11: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, no regressions in `spec/system/glossary_tooltip_spec.rb`, `spec/helpers/glossary_helper_spec.rb`, or any dashboard/history/response spec.

- [ ] **Step 12: Commit**

```bash
git add app/views/dashboard/_exercise.html.erb app/views/responses/_answered_sections.html.erb app/views/responses/_architecture_section.html.erb app/views/responses/_security_review_section.html.erb app/views/responses/_parsons_problem_section.html.erb spec/requests/glossary_search_placement_spec.rb
git commit -m "$(cat <<'EOF'
Wire glossary search into every remaining section

Rolls the box out to pattern/challenge on the dashboard, all three
sections in the read-only submitted/history render, and the
architecture/security_review/parsons_problem third-slot partials —
completing coverage across all six section partials.
EOF
)"
```
