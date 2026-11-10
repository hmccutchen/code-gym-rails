# lib/comment_check/c_style_scan.rb

## Regex literals in JavaScript

A JavaScript regex literal can hold `//` or `/*`, as in `/https?:\/\//` or `/[/*]/`, and a scanner that only knows about strings reads a comment there (#756). Telling a regex from division needs the parser's knowledge of whether the `/` starts an expression, and a full JavaScript tokenizer is more than a comment counter needs. `CStyleScan` uses the usual shortcut instead.

When it meets a `/` outside a string and comment in JavaScript, it looks at what comes before it, ignoring whitespace:

- **Read as a regex:** nothing at all (the start of the text), one of the punctuators `( , = : [ ! & | ? { } ; + - * % < > ~ ^`, or one of the keywords `return`, `typeof`, `instanceof`, `in`, `of`, `new`, `delete`, `void`, `throw`, `case`, `do`, `else`, `yield`, `await`.
- **Read as division:** anything else, which in practice is an identifier, a number, `)` or `]`.

A regex runs to the next `/` that is not escaped and not inside a `[...]` class. If the line ends first, the `/` was not a regex after all, and scanning carries on from the character after it.

Where the line is drawn, and what it gets wrong:

- A regex right after `)`, such as `if (ready) /x/.test(name)`, reads as division. Wrapping the regex in parentheses avoids it.
- A `/` after `}` reads as a regex. That is right after a block and wrong after an object literal (`{ a: 1 } / 2`), which code rarely divides.
- The look-back is 32 characters and does not skip comments, so a regex on the line after a `//` comment that ends in a word reads as division.
- Template literal `${...}` parts are read as part of the string, as before.

CSS has no regex literals, so the check runs only when `line_comments:` is on, which is how `Scanners.js_comments` calls it.

Over every tracked file the change found the same comments as the scanner before it; `spec/lib/comment_check_spec.rb` covers regex literals, division, and a comment after each.
