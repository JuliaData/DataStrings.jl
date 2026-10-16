# Changelog

## Unreleased

- Column construction and edits convert non-UTF-8 `AbstractString` inputs
  (UTF-16, UTF-32, Latin-1) to UTF-8 text, as `DataString(s)` already did.
  They previously failed or stored the raw code units.

## 1.1.0

- `convert(DataBytes, bytes)` for any `AbstractVector{UInt8}`.
- `DataStrings.materialize` accepts a plain vector of `DataString` or `DataBytes`
  values, with or without `missing`, and copies them out of their buffers.

## 1.0.0

Initial public release of DataStrings. See README.md for the API, representation,
limits, and validation commands.
