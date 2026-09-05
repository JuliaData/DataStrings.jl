# DataStrings maintenance

Compact inline or retained-view strings and byte columns.

Read README.md before changing the API. Validate external payload geometry before exposing a view. Preserve buffer ownership. Column edits must keep retained values valid. Keep payloads 16 bytes. Test malformed UTF-8 against String. Keep only DataString exported.

Run the complete suite on Julia 1.10 and current stable. Run the trim workload
before release. CI, registry merge, and release tag are separate checks.
