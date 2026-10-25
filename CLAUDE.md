# OrbitDeck for iOS — notes for contributors and coding assistants

## Language

Use **American English** everywhere: user-facing text, code comments, commit messages, documentation and the `docs/` website (color, center, meter, behavior, canceled, cataloged, analyze, favorite, gray, …). Apple and third-party API names keep their own spelling (e.g. `Task.isCancelled`, `URLError.Code.cancelled`) — never rename those.

## Project structure

- New app source files are not picked up by the Xcode target automatically (the app target is not a synchronized folder), so add new code to existing in-target files. The `OrbitDeckIOSTests` folder *is* synchronized: new test files there are compiled automatically.
- `OrbitDeckWidgets/` is the widget extension (the next-pass Live Activity / Dynamic Island). It is a synchronized folder too. Its `OrbitDeckPassAttributes` is duplicated in `OrbitDeckIOS/Models/OrbitStore.swift` (the app target can't see extension files); keep the two copies identical.
- Never edit `OrbitDeckIOS.xcodeproj/project.pbxproj` by hand.

## Licensing

OrbitDeck is MIT-licensed and distributed on the App Store. GPL/AGPL projects (e.g. OscarWatch, the B.B. Link firmware) may be used as behavioral references only — don't copy or port their code.
