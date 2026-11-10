# lib/comment_check/scanners.rb

## Files with no extension

`Scanners.for` picks a scanner by the file's extension. A file with no extension, such as most of `bin/`, has none to go by, so `Scanners.for` reads its first line instead:

- A `bash` or `sh` shebang (`#!/bin/bash -e`, `#!/usr/bin/env sh`) gets the shell scanner. It reads `#` comments that follow whitespace or start a line, so `$#` and `${#items[@]}` are not comments, and it ignores the shebang itself.
- A Ruby shebang gets no scanner. RuboCop already reads Ruby files, by extension or by the same shebang, and the house cops apply the comment rules there; reading them here too would report every offense twice. Ruby files with an extension are split the same way, since `.rb` has no entry in the extension table.
- Anything else, including a file with no shebang (`Gemfile`, `Dockerfile`), gets no scanner.

`CommentCheck.checked_path?` reads only the first line of a file with no extension, so a full-repository run does not load every image and font just to look for a shebang.

Before #755 every file with no extension was skipped, and `bin/docker-entrypoint` went unchecked. `spec/conventions/repo_files_spec.rb` now fails on a file under `bin/` that neither RuboCop nor `bin/comment-check` reads.
