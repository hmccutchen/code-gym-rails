// Reads a JSON array of code strings on stdin and writes a JSON array of the
// same length: each entry formatted, or null where Prettier could not parse
// it. The TSX parser reads plain JavaScript, JSX and TypeScript alike.
import { format } from "prettier";

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const snippets = JSON.parse(Buffer.concat(chunks).toString("utf8"));

const formatted = await Promise.all(
  snippets.map((code) => format(code, { parser: "typescript", filepath: "snippet.tsx" }).catch(() => null))
);
process.stdout.write(JSON.stringify(formatted));
