# app/views/dashboard/_teaching_hint.html.erb

## Locked hint and the template

A locked hint renders as a plain line, and the disclosure is not in the
document at all. It waits inside the `<template>`, so no key, click or
assistive technology can open it before the section is attempted. The
dashboard script swaps the line and the disclosure whenever the answer
crosses the answered threshold, in either direction.
