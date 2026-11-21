# Strings

`strings.js` is every game's strings tool: it checks that each language's
`.strings` tables match the base, exports them for translators and imports
their work back, lays translations out as the base, and builds tables from
JSON. Node only, no dependencies, and nothing leaves the machine: it never
calls a translation service.

`node Tools/Strings/strings.js --help` lists the commands and flags.

## A game's strings directory

Each game keeps `Tools/Strings/` with:

| File | What it holds |
|---|---|
| `strings.js` | Two lines that run this tool on this directory (below). |
| `strings.json` | The game's settings (below). Every key is optional. |

```js
#!/usr/bin/env node
// The game's strings: the runtime's Tools/Strings/strings.js on this directory.
process.env.STRINGS_DIR = __dirname;
require('../../Android/spritekit-android/Tools/Strings/strings.js');
```

| Key | What it says |
|---|---|
| `root` | The repository root, relative to the strings directory (default `../..`). Every other path is relative to it. |
| `lproj` | The folder holding the `<language>.lproj` folders (default `Assets`). |
| `base` | The base language's folder name, without `.lproj` (default `Base`; `en` when English is a language folder of its own). |
| `sourceLanguage` | The base's language code in exports (default `en`). |
| `languages` | The translations, by folder name (default every `.lproj` folder but the base's). |
| `tables` | The tables, by name without `.strings` (default every `.strings` file in the base folder). |
| `placeholders` | `printf` (Foundation's format specifiers, the default), `braces` (numbered `{1}`), or both in a list. |
| `order` | Whether a translation must keep the base's order (default `true`). |
| `layer` | The type-safe strings layer: `{ "file": "Source/Utils/LocalizedString.swift", "property": "key", "tables": ["Localizable"] }`. `property` names the `var` whose `switch` returns each case's key (`case .play: return "title.play"`), so English fallbacks and translator comments elsewhere in the file aren't taken for keys; `pattern` replaces that match (a regular expression whose first group is the key); `tables` limits the tables (and the base's `.stringsdict` files) it reads from. A list checks several layers. |
| `generate` | For tables built from JSON (below). |

## Commands

- **`check`** reads every table in every language against the base: syntax,
  duplicate keys, keys missing or not in the base, the base's order, and
  placeholders (positional ones may move: `%2$@ … %1$@` matches
  `%1$@ … %2$@`). Then every key the strings layer names must be in a base
  table or `.stringsdict`. It exits 1 on any problem. `--unused` also lists
  the base keys the layer doesn't name; some are built in code, so those
  are only listed.
- **`export`** writes the strings for translators, to `--out <file>` or
  standard output: `--format json` (the default; by language, then table, a
  list of `{ key, source, target, note }`, the note being the comment above
  the base's entry), `csv` (a row per key: `table`, `key`, `note`, the base,
  then a column per language) or `xliff` (XLIFF 1.2, a `<file>` per language
  and table, as Xcode exports). `--missing` leaves out what a language
  already has.
- **`import <file>`** reads translations back from any of those formats (by
  the extension, or `--format`) and writes them into each language's tables,
  laid out as the base. A string the file leaves empty is left as it was.
- **`sync`** lays every translation out as its base: the base's comments,
  blank lines and order, the translation's values, under the translation's
  own header comment. Keys the base doesn't have are dropped and keys it
  lacks are listed; `check` still fails on them until they're translated.
- **`generate`** builds tables from JSON (`generate` in the settings), for a
  game whose text comes from elsewhere:

  ```json
  "generate": {
    "table": "Localizable",
    "languages": ["en", "fr"],
    "sources": [
      { "file": "i18n/{language}/singular.json" },
      { "file": "i18n/{language}/plural.json", "plural": "{key}#{form}" },
      { "file": "Tools/Strings/extra.json", "select": "{language}", "optional": true }
    ]
  }
  ```

  Each source is a JSON object of key to text. `plural` reads `{ form: text
  }` values into one key per form; `select` takes one member of the object;
  `optional` skips a missing file. Lines are written `"key" = "value";` in
  the sources' order, and the table goes from languages no longer listed.

`--lang` and `--table` narrow any command; `--dry-run` makes `import`,
`sync` and `generate` say what would change without writing.

## Translating new strings

```bash
node Tools/Strings/strings.js export --missing --out /tmp/missing.json
# translate each `target` in the file
node Tools/Strings/strings.js import /tmp/missing.json
node Tools/Strings/strings.js check
```

## Tests

```bash
node --test Tools/Strings/strings.test.js
```
