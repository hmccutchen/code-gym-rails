# lib/comment_check/scanners.rb

## Files with no extension

`Scanners.for` picks a scanner by the file's extension. A file with no extension, such as most of `bin/`, has none to go by, so `Scanners.for` reads its first line instead:

- A `bash` or `sh` shebang (`#!/bin/bash -e`, `#!/usr/bin/env sh`) gets the shell scanner. It reads `#` comments that follow whitespace or start a line, so `$#` and `${#items[@]}` are not comments, and it ignores the shebang itself.
- A Ruby shebang gets no scanner. RuboCop already reads Ruby files, by extension or by the same shebang, and the house cops apply the comment rules there; reading them here too would report every offense twice. Ruby files with an extension are split the same way, since `.rb` has no entry in the extension table.
- Anything else, including a file with no shebang (`Gemfile`, `Dockerfile`), gets no scanner.

`CommentCheck.checked_path?` opens only files with no extension, and reads only their first line, so deciding which files to check stays cheap on a full-repository run.

Before #755 every file with no extension was skipped, and `bin/docker-entrypoint` went unchecked. `spec/conventions/repo_files_spec.rb` now fails on a file under `bin/` that neither RuboCop nor `bin/comment-check` reads.

## YAML block scalars

A `|` or `>` at the end of a YAML value starts a block scalar: the lines indented below it are text, so a `#` there is part of the value, not a comment (#756). `Scanners.yaml_comments` blanks those lines out before it looks for comments, keeping every line's length so the line numbers it reports stay right.

A block opens on any line, other than a comment line, whose value ends in a `|` or `>` that follows whitespace. The indicator may carry a chomping or indentation mark (`|-`, `>+`, `|2`) and a trailing comment, and that comment still counts. The block holds every following line that is blank or indented further than the line that opened it, and ends at the first line that is not. That covers `key: |` and a list item's `- |`.

A plain value that happens to end in ` |` (`command: echo a |`) also opens a block. The lines below it are a sibling key or less indented, so the block ends at once and nothing is lost.
