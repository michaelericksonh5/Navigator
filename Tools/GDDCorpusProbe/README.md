# GDD corpus probe

Runs the real parser over the real GDD folder and prints what it read, per document.

This exists because the parser was verified against hand-written fixtures and shipped
reading **one of seven** actual documents. Fixtures agree with whoever wrote them; the
folder does not.

```bash
swiftc -O -o dump dump.swift -framework AppKit          # .docx -> .txt, the app's own reader
./dump /tmp/gddtext "<GDD folder>"/*.docx
swiftc -O -o probe ../../NavigatorCore.swift main.swift -framework AppKit
./probe /tmp/gddtext
```

Run it after any change to `GDDSymbolSetRules`. A document that parses to nothing is a
pass only when it genuinely declares no symbols.
