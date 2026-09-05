# DataStrings.jl

Compact string and byte columns for Julia data tools. Short values store up to
12 bytes inline. Longer values store a prefix and a reference into retained
byte buffers. The 16-byte payload follows Arrow Utf8View/BinaryView.

DataStrings combines the ArrowStrings payload validation and multi-buffer work
with the CSV CompactString construction and mutable-column work. It has no
runtime package dependencies and supports Julia 1.10 and later.

```julia
using DataStrings

s = DataString("hello")
@assert s == "hello"
@assert hash(s) == hash("hello")
@assert String(s) == "hello"

col = DataStrings.StringVector(["short", "a longer string value"])
held = col[2]
col[2] = "replacement"
push!(col, "another long string value")
@assert held == "a longer string value"
@assert DataStrings.materialize(col) == ["short", "replacement", "another long string value"]

nullable = DataStrings.StringVector(Union{Missing,String}["value", missing])
@assert ismissing(nullable[2])
bytes = DataStrings.DataBytes(UInt8[0x00, 0xff])
@assert collect(bytes) == [0x00, 0xff]
```

After registration, install with `import Pkg; Pkg.add("DataStrings")`.

## Public API

Only `DataString` is exported. Use `DataStrings.` for the other public names.

- `DataString <: AbstractString`: payload plus a retained byte vector. String
  construction copies content; construction from another DataString is identity.
  Equality, hashing, ordering, character indexing, and iteration match String,
  including Julia's tolerant handling of malformed UTF-8. `String`, regex
  operations, and `reverse` can allocate a String.
- `StringVector{DataString}` or `StringVector{Union{Missing,DataString}}`: mutable
  column. Supports indexing, assignment, push/pop, insertion, deletion, copying,
  and resizing. New slots contain `""` or `missing`, respectively.
- `DataBytes <: AbstractVector{UInt8}`: byte counterpart. `DataBytes(bytes)` copies
  content. Equality and hashing agree with byte vectors. `Vector{UInt8}(b)` copies.
- `BytesVector{DataBytes}` or `BytesVector{Union{Missing,DataBytes}}`: read-only
  binary column over supplied payloads and buffers.
- `StringPayload`, `inline_payload`, `view_payload`, `rebase_payload`,
  `payloadlength`, `payloadbufidx`, `payloadoffset`, `payloadpos`, `INLINE_MAX`,
  and `PAYLOAD_MISSING`: supported builder interface.
- `materialize(column)`: copy the current values into ordinary Julia strings or
  byte vectors. Nullable columns preserve missing values.

## Buffer interface

A StringPayload is two UInt64 words. The low 32 bits of the first word hold the
byte length. Its high 32 bits hold the first four bytes. For lengths up to 12,
word two holds the remaining bytes, padded with zeros. For longer values, word
two holds an Int32 buffer index and an Int32 byte offset. Both are zero-based.
These bit definitions are portable. Raw payload bytes match the little-endian
Arrow layout on little-endian hosts; other byte orders need field-aware encoding.

```julia
using DataStrings
buf = collect(codeunits("a long string in a shared buffer"))
payload = DataStrings.view_payload(buf, 1, length(buf), 0, 0)
col = DataStrings.StringVector{DataString}([payload], [buf])
@assert col[1] == "a long string in a shared buffer"
```

The checked constructors validate length, padding, missing markers, buffer index,
range, and prefix. StringVector copies the buffer-reference list and adds a
private append-only arena; it retains the supplied payload vector and byte
buffers. BytesVector retains the supplied vectors. Scalar values retain their
byte vector, so collecting a column does not invalidate previously read values.

Column methods append bytes rather than overwriting existing content. Retained
values stay valid across supported edits. Deleted content remains allocated while
its arena has owners. Use `materialize` to detach live values. Direct mutation or
resizing of supplied payloads/buffers can invalidate values and is unsupported.
Concurrent column mutation needs external synchronization.

The trailing `Val(:trusted)` column constructor skips payload validation. It is
for builders that already proved all checked-constructor invariants. Invalid
trusted payloads can cause out-of-bounds memory access. External data must use
checked constructors. The scalar `Val(:unchecked)` constructor is internal.

Lengths, offsets, and buffer indices must fit the nonnegative Int32 range.
StringVector's internal missing marker is not an Arrow validity bitmap. Writers
must emit Arrow null metadata and validate UTF-8 for Utf8View. BinaryView permits
arbitrary bytes. DataString itself follows String's tolerant byte semantics.

## Validation and provenance

CI tests Julia 1.10, 1.11, current stable, and nightly across Linux, Windows, and
macOS. A separate job compiles and executes a representative workload with
JuliaC `--trim=safe`. Tests cover malformed UTF-8, payload geometry, seeded hash
agreement, zero-allocation read kernels, mutable columns, and retained lifetimes.

Run `julia --project -e 'using Pkg; Pkg.test()'`. For trim tests:

```sh
julia --project=test/trim -e 'using Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'
julia --project=test/trim test/trim/runtests.jl
```

This is an independent JuliaData package derived from ArrowStrings and CSV work.
It is not an Apache Software Foundation release. Original Apache 2.0 and MIT
notices are retained in LICENSE.md, NOTICE, and LICENSE-CSV.md. See PROVENANCE.md.
