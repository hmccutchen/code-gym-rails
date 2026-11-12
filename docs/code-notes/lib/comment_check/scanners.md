# lib/comment_check/scanners.rb

## Files with no extension

`Scanners.for` picks a scanner by the file's extension. A file with no extension, such as most of `bin/`, has none to go by, so `Scanners.for` reads its first line instead:

- A `bash` or `sh` shebang (`#!/bin/bash -e`, `#!/usr/bin/env sh`) gets the shell scanner. It reads `#` comments that follow whitespace or start a line, so `$#` and `${#items[@]}` are not comments, and it ignores the shebang itself. A heredoc's body (`cat <<'EOF'` through `EOF`, quoted or not, and `<<-` with tab-indented lines) is text passed to a command, so the scanner blanks it, keeping line positions, before it looks for comments. A `<<` opens a heredoc only in shell code: not inside quotes (`echo "usage: tool <<EOF"`), not after a `#` that starts a comment, and not inside `((...))` arithmetic (`$((1 << 2))`). A heredoc whose delimiter line never appears is not blanked at all, so a false match can never hide the rest of a file.
- A Ruby shebang gets no scanner. RuboCop already reads Ruby files, by extension or by the same shebang, and the house cops apply the comment rules there; reading them here too would report every offense twice. Ruby files with an extension are split the same way, since `.rb` has no entry in the extension table.
- Anything else, including a file with no shebang (`Gemfile`, `Dockerfile`), gets no scanner.

`CommentCheck.checked_path?` opens only files with no extension, and reads only their first line, so deciding which files to check stays cheap on a full-repository run.

Before #755 every file with no extension was skipped, and `bin/docker-entrypoint` went unchecked. `spec/conventions/repo_files_spec.rb` now fails on a file under `bin/` that neither RuboCop nor `bin/comment-check` reads.

## YAML block scalars

A `|` or `>` at the end of a YAML value starts a block scalar: the lines indented below it are text, so a `#` there is part of the value, not a comment (#756). `Scanners.yaml_comments` blanks those lines out before it looks for comments, keeping every line's length so the line numbers it reports stay right.

Ruby's YAML parser, Psych, finds the blocks. `Psych.parse_stream` returns every scalar with its style and position, and the scanner blanks the lines of each literal (`|`) or folded (`>`) scalar after its indicator line. Psych reports a block's end as the start of the first line it does not cover, so that line is left alone. Earlier versions guessed blocks from indentation, and reviews kept finding cases the guess got wrong: a plain value ending in `|`, a list item's next key, a comment indented less than the block's text, and a `: |` inside a comment. Psych has the rules of YAML, so each of those comes out right, and `spec/lib/comment_check_spec.rb` keeps a case for every one.

A file Psych cannot parse, such as `config/database.yml` with its ERB tags, is scanned with no blocks blanked. Every `#` line in it then counts, so a mistake there over-reports a comment and never hides one. Over every tracked YAML file the switch found the same comments as the indentation rules before it.
