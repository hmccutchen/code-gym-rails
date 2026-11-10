pin "application"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/code_gym", under: "code_gym"
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11.17.2/dist/mermaid.esm.min.mjs", preload: false
pin "sortablejs", to: "https://cdn.jsdelivr.net/npm/sortablejs@1.15.6/modular/sortable.esm.js", preload: false
