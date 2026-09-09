# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

"""
    DataStrings

An inline-else-view string representation for Arrow.jl and compatible parsers:
`DataString`, a string value whose 16-byte payload IS an Arrow StringView
entry, and `StringVector`, a column of them over a set of byte buffers that IS
an Arrow Utf8View array's memory. A column parsed into this representation can
be written as an Arrow column without repacking its payloads or data buffers.

Every string is one 16-byte payload (`StringPayload`, two `UInt64`
words `a` and `b`, packed by explicit shifts so the layout is
endianness-independent):

    a  bits 0..31   content length as Int32 (-1 marks a missing value)
       bits 32..63  content bytes 1..4 — the full bytes when the string is
                    inline (length ≤ 12), the 4-byte PREFIX when it is a view
                    (one word compare — length + prefix — rejects most
                    unequal views)
    b  length ≤ 12  content bytes 5..12, zero-padded
       length > 12  bits 0..31 an Int32 BUFFER INDEX and bits 32..63 an Int32
                    0-based byte OFFSET of the content within that buffer

That is byte for byte the Arrow StringView layout (12-byte inline, 4-byte
prefix, int32 buffer index + int32 offset). Arrow's Int32 words are why a
buffer must stay under 2 GiB. Byte access, comparison, hashing, and iteration
never allocate; `String(s)` copies out; `materialize(v)` copies a whole
column out to `Vector{String}`. Everything here depends only on Base and uses
concrete types throughout.

The same payload is Arrow's BinaryView entry, so the package also carries the
bytes counterparts: `DataBytes`, an opaque binary value over one payload, and
`BytesVector`, a column of them that IS a BinaryView array's memory.

Lifetime: an `DataString` view pins its buffer (`data`), and a
`StringVector` pins all of its buffers, exactly like any zero-copy
string view; a consumer that must outlive the source materializes.
"""
module DataStrings

export DataString

# Mark the supported non-exported surface with public. It goes through
# Core.eval because Julia < 1.11 cannot parse the public keyword at all.
@static if VERSION >= v"1.11"
    Core.eval(
        @__MODULE__,
        Expr(
            :public,
            :DataBytes,
            :StringVector,
            :BytesVector,
            :StringPayload,
            :inline_payload,
            :view_payload,
            :rebase_payload,
            :payloadlength,
            :payloadbufidx,
            :payloadoffset,
            :payloadpos,
            :materialize,
            :PAYLOAD_MISSING,
            :INLINE_MAX,
        ),
    )
end

"""
    StringPayload

One 16-byte inline-else-view string entry — an Arrow StringView entry (see
[`DataStrings`](@ref) for the word layout). `payloadlength(p)` is the length
(negative for missing); for a view, `payloadbufidx(p)` and `payloadoffset(p)` are its
buffer index and 0-based offset, and `payloadpos(p)` the 1-based position.
"""
struct StringPayload
    a::UInt64
    b::UInt64
end

"The payload of a missing value: length -1."
const PAYLOAD_MISSING = StringPayload(UInt64(0xffffffff), zero(UInt64))
"Longest string stored inline; longer strings are views into a buffer."
const INLINE_MAX = 12
const EMPTY_BYTES = UInt8[]

"Return the content byte length; a negative result marks a missing value."
@inline payloadlength(p::StringPayload) = reinterpret(Int32, p.a % UInt32)
"Return the zero-based referenced-buffer index of a view payload."
@inline payloadbufidx(p::StringPayload) = reinterpret(Int32, p.b % UInt32)
"Return the zero-based byte offset of a view payload within its buffer."
@inline payloadoffset(p::StringPayload) = reinterpret(Int32, (p.b >> 32) % UInt32)
"Return the one-based byte position of a view payload within its buffer."
@inline payloadpos(p::StringPayload) = Int(payloadoffset(p)) + 1
@inline _viewword(bufidx::Integer, offset0::Integer) =
    UInt64(bufidx % UInt32) | (UInt64(offset0 % UInt32) << 32)

@inline function _checkrange(src::AbstractVector, pos::Int, len::Int, label::String)
    Base.require_one_based_indexing(src)
    n = length(src)
    # pos == n+1 is legal for len == 0: an empty string at the end of a buffer.
    (1 <= pos <= n + 1 && len <= n - pos + 1) ||
        throw(BoundsError("$label: range starts at $pos with length $len in $n bytes"))
    return nothing
end

@inline function _inline_payload_loop(src::AbstractVector{UInt8}, pos::Int, len::Int)
    a = UInt64(len % UInt32)
    b = zero(UInt64)
    @inbounds for i = 1:min(len, 4)
        a |= UInt64(src[pos + i - 1]) << (32 + 8 * (i - 1))
    end
    @inbounds for i = 5:len
        b |= UInt64(src[pos + i - 1]) << (8 * (i - 5))
    end
    return StringPayload(a, b)
end

"""
    inline_payload(src::AbstractVector{UInt8}, pos::Int, len::Int) -> StringPayload

The payload of the `len` (≤ 12) bytes of `src` starting at 1-based `pos`,
stored inline. The requested byte range is checked before it is read.
`src` must use one-based indexing.
"""
@inline function inline_payload(src::AbstractVector{UInt8}, pos::Int, len::Int)
    0 <= len <= INLINE_MAX ||
        throw(ArgumentError("inline_payload: length $len is not in 0:$INLINE_MAX"))
    _checkrange(src, pos, len, "inline_payload")
    return _inline_payload_loop(src, pos, len)
end

# Two overlapping little-endian loads gather up to 12 content bytes
# branch-free; the byte-loop fallback only runs within 11 bytes of the
# buffer's end.
@inline function inline_payload(src::Vector{UInt8}, pos::Int, len::Int)
    0 <= len <= INLINE_MAX ||
        throw(ArgumentError("inline_payload: length $len is not in 0:$INLINE_MAX"))
    _checkrange(src, pos, len, "inline_payload")
    if pos <= length(src) - 11
        GC.@preserve src begin
            p = pointer(src, pos)
            lo = ltoh(unsafe_load(Ptr{UInt64}(p)))           # content bytes 1..8
            hi = ltoh(unsafe_load(Ptr{UInt64}(p + 4)))       # content bytes 5..12
        end
        m4 = len >= 4 ? 0x00000000ffffffff : (UInt64(1) << (8 * len)) - 1
        nb = max(len - 4, 0)
        m8 = nb >= 8 ? typemax(UInt64) : (UInt64(1) << (8 * nb)) - 1
        return StringPayload(UInt64(len % UInt32) | ((lo & m4) << 32), hi & m8)
    end
    return _inline_payload_loop(src, pos, len)
end

"""
    view_payload(src::AbstractVector{UInt8}, srcpos::Int, len::Int, bufidx, offset0) -> StringPayload

The payload of a view. The first four content bytes sit at 1-based `srcpos`
in `src`; the complete `len` (> 12) bytes are addressed by buffer index
`bufidx` and 0-based byte `offset0`. The prefix range is checked. A length or
word that does not fit Arrow's Int32 is refused because an oversized value
would wrap into the null marker. `src` must use one-based indexing.
"""
@inline function view_payload(
    src::AbstractVector{UInt8},
    srcpos::Int,
    len::Int,
    bufidx::Integer,
    offset0::Integer,
)
    INLINE_MAX < len <= typemax(Int32) || throw(
        ArgumentError(
            "view_payload: length $len is not in $(INLINE_MAX + 1):$(typemax(Int32))",
        ),
    )
    (0 <= offset0 <= typemax(Int32) && 0 <= bufidx <= typemax(Int32)) || throw(
        ArgumentError(
            "DataString view (buffer $bufidx, offset $offset0) " *
            "does not fit Arrow's Int32 view words; buffers must stay under 2 GiB",
        ),
    )
    _checkrange(src, srcpos, 4, "view_payload")
    pre = zero(UInt32)
    @inbounds for i = 0:3
        pre |= UInt32(src[srcpos + i]) << (8 * i)
    end
    a = UInt64(len % UInt32) | (UInt64(pre) << 32)
    return StringPayload(a, _viewword(bufidx, offset0))
end

"""
    rebase_payload(p::StringPayload, base::Integer) -> StringPayload

The same view entry re-pointed `base` bytes further into its buffer — what
concatenating buffers (a chunk's buffer appended to a column's) needs.
"""
@inline function rebase_payload(p::StringPayload, base::Integer)
    payloadlength(p) > INLINE_MAX ||
        throw(ArgumentError("rebase_payload requires an out-of-line view payload"))
    # base may not fit Int and the sum may overflow; both are user-visible
    # errors, not exceptions to propagate.
    shift = try
        Int(base)
    catch
        throw(ArgumentError("DataString view offset adjustment $base does not fit Int"))
    end
    off = try
        Base.checked_add(Int(payloadoffset(p)), shift)
    catch
        throw(ArgumentError("rebased DataString view offset overflow"))
    end
    0 <= off <= typemax(Int32) || throw(
        ArgumentError(
            "rebased DataString view offset $off does not fit " *
            "Arrow's Int32 view offset; buffers must stay under 2 GiB",
        ),
    )
    return StringPayload(p.a, _viewword(payloadbufidx(p), off))
end

@inline _inlinebyte(p::StringPayload, i::Int) =
    i <= 4 ? (p.a >> (32 + 8 * (i - 1))) % UInt8 : (p.b >> (8 * (i - 5))) % UInt8

"""
Check one payload against its data buffer: missing marker exactness, inline
zero padding, view range, and prefix agreement. `missingok=true` accepts only
the exact `PAYLOAD_MISSING` sentinel.
"""
function _validate_payload(
    p::StringPayload,
    data::Vector{UInt8};
    missingok::Bool=false,
)
    len = payloadlength(p)
    if len < 0
        missingok && p == PAYLOAD_MISSING ||
            throw(ArgumentError("invalid missing DataString payload"))
        return nothing
    end
    if len <= INLINE_MAX
        for i = (Int(len) + 1):INLINE_MAX
            iszero(_inlinebyte(p, i)) ||
                throw(ArgumentError("inline DataString payload has nonzero padding"))
        end
        return nothing
    end
    off = Int(payloadoffset(p))
    0 <= off <= length(data) || throw(
        ArgumentError(
            "DataString view offset $off is outside a $(length(data))-byte buffer",
        ),
    )
    Int(len) <= length(data) - off || throw(
        ArgumentError(
            "DataString view of length $len at offset $off escapes a $(length(data))-byte buffer",
        ),
    )
    @inbounds for i = 0:3
        _inlinebyte(p, i + 1) == data[off + i + 1] ||
            throw(ArgumentError("DataString view prefix does not match its data buffer"))
    end
    return nothing
end

"""
    DataString <: AbstractString

A string value: its 16-byte payload plus the byte vector a view's content
lives in (a shared empty vector for inline values). Byte access, direct
comparisons, hashing, and iteration do not allocate; they use the inline
bytes or the retained buffer. Hashing and ordering agree with `String`.
`String(s)` copies out. The two-argument constructor validates the payload
and throws `ArgumentError`; `Val(:unchecked)` is the internal bypass.
"""
struct DataString <: AbstractString
    p::StringPayload
    data::Vector{UInt8}    # dereferenced only when the payload is a view
    function DataString(p::StringPayload, data::Vector{UInt8})
        _validate_payload(p, data)
        return new(p, data)
    end
    DataString(p::StringPayload, data::Vector{UInt8}, ::Val{:unchecked}) =
        new(p, data)
end

@inline _unchecked_datastring(p::StringPayload, data::Vector{UInt8}) =
    DataString(p, data, Val(:unchecked))

Base.ncodeunits(s::DataString) = Int(payloadlength(s.p))
Base.codeunit(::DataString) = UInt8
Base.@propagate_inbounds function Base.codeunit(s::DataString, i::Int)
    @boundscheck 1 <= i <= ncodeunits(s) || throw(BoundsError(s, i))
    len = payloadlength(s.p)
    if len <= INLINE_MAX
        return i <= 4 ? (s.p.a >> (32 + 8 * (i - 1))) % UInt8 :
               (s.p.b >> (8 * (i - 5))) % UInt8
    else
        return @inbounds s.data[payloadpos(s.p) + i - 1]
    end
end

function Base.isvalid(s::DataString, i::Int)
    1 <= i <= ncodeunits(s) || return false
    @inbounds b = codeunit(s, i)
    b & 0xc0 == 0x80 || return true
    i > 1 || return true
    @inbounds b = codeunit(s, i - 1)
    0xc0 <= b <= 0xf7 && return false
    b & 0xc0 == 0x80 && i > 2 || return true
    @inbounds b = codeunit(s, i - 2)
    0xe0 <= b <= 0xf7 && return false
    b & 0xc0 == 0x80 && i > 3 || return true
    @inbounds b = codeunit(s, i - 3)
    return !(0xf0 <= b <= 0xf7)
end

# UTF-8 iteration mirroring `String`'s tolerant behavior: Julia `Char`s ARE the
# UTF-8 bytes left-aligned in 32 bits, and a malformed sequence yields the bytes
# consumed so far as an (invalid) Char.
function Base.iterate(s::DataString, i::Int=1)
    i >= 1 || throw(BoundsError(s, i))
    i > ncodeunits(s) && return nothing
    @inbounds b1 = codeunit(s, i)
    b1 < 0x80 && return (reinterpret(Char, UInt32(b1) << 24), i + 1)
    l = b1 < 0xc0 ? 1 : b1 < 0xe0 ? 2 : b1 < 0xf0 ? 3 : b1 < 0xf8 ? 4 : 1
    n = ncodeunits(s)
    c = UInt32(b1) << 24
    j = 1
    @inbounds while j < l && i + j <= n
        nb = codeunit(s, i + j)
        (nb & 0xc0) == 0x80 || break
        c |= UInt32(nb) << (24 - 8 * j)
        j += 1
    end
    return (reinterpret(Char, c), i + j)
end

# Base's generic AbstractString length is isvalid-count-based, which undercounts
# malformed inputs (String yields each bare continuation byte as its own invalid
# Char). Count by iteration so length/collect agree with String.
function Base.length(s::DataString)
    n = 0
    for _ in s
        n += 1
    end
    return n
end

function Base.:(==)(x::DataString, y::DataString)
    n = ncodeunits(x)
    n == ncodeunits(y) || return false
    if n <= INLINE_MAX
        return x.p.a == y.p.a && x.p.b == y.p.b   # payload holds the full content
    end
    x.p.a == y.p.a || return false                # length + 4-byte prefix reject
    GC.@preserve x y begin
        return ccall(
            :memcmp,
            Cint,
            (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
            pointer(x.data, payloadpos(x.p)),
            pointer(y.data, payloadpos(y.p)),
            n,
        ) == 0
    end
end
# Direct byte comparison against String — Base's generic AbstractString ==
# decodes chars, an order of magnitude slower on this hot path (filtering and
# grouping compare DataString columns against String literals constantly).
function Base.:(==)(x::DataString, y::Union{String,SubString{String}})
    n = ncodeunits(x)
    n == ncodeunits(y) || return false
    GC.@preserve x y begin
        py = pointer(y)
        if n <= INLINE_MAX
            @inbounds for i = 1:n
                codeunit(x, i) == unsafe_load(py, i) || return false
            end
            return true
        end
        return ccall(
            :memcmp,
            Cint,
            (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
            pointer(x.data, payloadpos(x.p)),
            py,
            n,
        ) == 0
    end
end
Base.:(==)(y::Union{String,SubString{String}}, x::DataString) = x == y

# Ordering: memcmp over the bytes, exactly like String's `cmp` (Base's generic
# AbstractString fallback iterates chars — 15-45x slower on sortperm).
# Inline×inline compares in registers; view×view goes straight to memcmp on
# the retained buffers; only the mixed case materializes a stack scratch.
# Raw payload words with content byte k at byte k (byte 1 = LSB of w1) —
# bit-defined, so endian-independent.
@inline _payload_words(s::DataString) =
    ((s.p.a >> 32) | ((s.p.b & 0xffffffff) << 32), s.p.b >> 32)
@inline _payload_scratch(s::DataString) = map(htol, _payload_words(s))
function Base.cmp(x::DataString, y::DataString)
    nx, ny = ncodeunits(x), ncodeunits(y)
    if (nx <= INLINE_MAX) & (ny <= INLINE_MAX)
        # Inline×inline compares in registers. Payload words are zero-padded
        # past each length, so the first differing big-endian word decides on
        # its first differing byte; all-equal words mean the shorter string is
        # a prefix of the longer. That is memcmp(min bytes) plus the length
        # tiebreak. `&` (not `&&`) keeps this to one branch.
        w1x, w2x = _payload_words(x)
        w1y, w2y = _payload_words(y)
        a, b = bswap(w1x), bswap(w1y)
        a == b || return a < b ? -1 : 1
        a, b = bswap(w2x), bswap(w2y)
        a == b || return a < b ? -1 : 1
        return cmp(nx, ny)
    end
    n = min(nx, ny)
    rx = Ref(_payload_scratch(x))
    ry = Ref(_payload_scratch(y))
    GC.@preserve x y rx ry begin
        px =
            nx <= INLINE_MAX ?
            Ptr{UInt8}(Base.unsafe_convert(Ptr{Tuple{UInt64,UInt64}}, rx)) :
            pointer(x.data, payloadpos(x.p))
        py =
            ny <= INLINE_MAX ?
            Ptr{UInt8}(Base.unsafe_convert(Ptr{Tuple{UInt64,UInt64}}, ry)) :
            pointer(y.data, payloadpos(y.p))
        c = ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), px, py, n)
    end
    return c < 0 ? -1 : c > 0 ? 1 : cmp(nx, ny)
end
function Base.cmp(x::DataString, y::Union{String,SubString{String}})
    nx, ny = ncodeunits(x), ncodeunits(y)
    n = min(nx, ny)
    rx = Ref(_payload_scratch(x))
    GC.@preserve x y rx begin
        px =
            nx <= INLINE_MAX ?
            Ptr{UInt8}(Base.unsafe_convert(Ptr{Tuple{UInt64,UInt64}}, rx)) :
            pointer(x.data, payloadpos(x.p))
        c = ccall(:memcmp, Cint, (Ptr{UInt8}, Ptr{UInt8}, Csize_t), px, pointer(y), n)
    end
    return c < 0 ? -1 : c > 0 ? 1 : cmp(nx, ny)
end
Base.cmp(y::Union{String,SubString{String}}, x::DataString) = -cmp(x, y)
Base.isless(x::DataString, y::DataString) = cmp(x, y) < 0
Base.isless(x::DataString, y::Union{String,SubString{String}}) = cmp(x, y) < 0
Base.isless(y::Union{String,SubString{String}}, x::DataString) = cmp(y, x) < 0

# hash contract: hash(s) == hash(String(s)) — DataStrings are Dict keys
# next to Strings. Base hashes a String's bytes through one C routine; we run
# the same routine over the bytes we already have: the retained buffer for
# views, a stack copy of the payload words for inline strings. No String
# allocation on either path. The routine differs across hashing generations:
#   ≤ 1.12  memhash(bytes, n, seed) + seed  with seed = h + memhash_seed
#   ≥ 1.13  hash_bytes(ptr, n, UInt64(h), HASH_SECRET) % UInt   (rapidhash)
# The gate is on the API that exists, not the version number.
@static if isdefined(Base, :hash_bytes) && isdefined(Base, :HASH_SECRET)
    @inline _stringhash(p::Ptr{UInt8}, n::Int, h::UInt) =
        Base.hash_bytes(p, n, UInt64(h), Base.HASH_SECRET) % UInt
else
    @inline function _stringhash(p::Ptr{UInt8}, n::Int, h::UInt)
        h += Base.memhash_seed
        return ccall(Base.memhash, UInt, (Ptr{UInt8}, Csize_t, UInt32), p, n, h % UInt32) +
               h
    end
end

function Base.hash(s::DataString, h::UInt)
    n = ncodeunits(s)
    if n > INLINE_MAX
        GC.@preserve s begin
            return _stringhash(pointer(s.data, payloadpos(s.p)), n, h)
        end
    end
    # inline: bytes 1-4 are the high 32 bits of `a`, bytes 5-12 are `b` —
    # pack them contiguously into two little-endian words: word 1 = bytes 1-8
    # = (a>>32) | (low 32 bits of b) << 32, word 2 = bytes 9-12 = b >> 32
    w1 = (s.p.a >> 32) | ((s.p.b & 0xffffffff) << 32)
    w2 = s.p.b >> 32
    scratch = (htol(w1), htol(w2))
    r = Ref(scratch)
    GC.@preserve r begin
        p = Ptr{UInt8}(Base.unsafe_convert(Ptr{Tuple{UInt64,UInt64}}, r))
        return _stringhash(p, n, h)
    end
end

function Base.String(s::DataString)
    n = ncodeunits(s)
    if n > INLINE_MAX
        # view: one memcpy out of the retained buffer
        GC.@preserve s begin
            return unsafe_string(pointer(s.data, payloadpos(s.p)), n)
        end
    end
    out = Vector{UInt8}(undef, n)
    @inbounds for i = 1:n
        out[i] = codeunit(s, i)
    end
    return String(out)
end
Base.convert(::Type{String}, s::DataString) = String(s)
Base.Symbol(s::DataString) = Symbol(String(s))
Base.promote_rule(::Type{DataString}, ::Type{String}) = String

function Base.write(io::IO, s::DataString)
    n = 0
    @inbounds for i = 1:ncodeunits(s)
        n += write(io, codeunit(s, i))
    end
    return n
end
Base.print(io::IO, s::DataString) = (write(io, s); nothing)

# Validate one column's payloads against its buffers — the shared body of the
# StringVector and BytesVector checked constructors.
function _validate_column(
    payloads::Vector{StringPayload},
    buffers::Vector{Vector{UInt8}},
    missingok::Bool,
    what::String,
)
    for p in payloads
        len = payloadlength(p)
        # Inline and missing payloads reference no buffer; pass the
        # shared empty vector so only the padding/marker checks run.
        if len < 0
            _validate_payload(p, EMPTY_BYTES; missingok=missingok)
        elseif len <= INLINE_MAX
            _validate_payload(p, EMPTY_BYTES)
        else
            bufidx = Int(payloadbufidx(p))
            0 <= bufidx < length(buffers) || throw(
                ArgumentError(
                    "$what view buffer index $bufidx is outside 0:$(length(buffers) - 1)",
                ),
            )
            _validate_payload(p, buffers[bufidx + 1])
        end
    end
    return nothing
end

"""
    StringVector{ELT}(payloads, buffers::Vector{Vector{UInt8}})
    StringVector{ELT}(payloads, buf::Vector{UInt8}, extra::Vector{UInt8})
    StringVector{ELT}(payloads, buffers, Val(:trusted))

A string column: one payload per element and the byte buffers that view
payloads point into (`buffers[bufidx + 1]` for an entry's buffer index).
`ELT` is `DataString` for a column with no missing values, or
`Union{Missing, DataString}`. `getindex` returns an `DataString` (or
`missing`) with NO allocation; `materialize` copies out to `Vector{String}`.

Construction validates every payload, including missing markers, inline
padding, buffer indices, byte ranges, and long-string prefixes. This makes
later zero-copy access safe. Do not resize or mutate the payload vector or any
buffer while the column is in use.

The `Val(:trusted)` constructor skips that validation. It is for builders
that produced every payload themselves from bounds they already checked — a
parser whose offsets were validated as they were read, for example — where
re-validating each entry would double the column's construction cost. The
caller vouches for every invariant the checked constructors enforce; a payload
that violates them makes later access read out of bounds. Payloads that come
from anywhere else go through a checked constructor.

This is an Arrow Utf8View array's memory: `payloads` is its views buffer and
`buffers` its variadic data buffers, so Arrow.jl can write the column without
repacking either one. The two-buffer constructor is the CSV shape: buffer 0
the input, buffer 1 the column's `extra` buffer of unescaped values.
"""
struct StringVector{ELT} <: AbstractVector{ELT}
    payloads::Vector{StringPayload}
    buffers::Vector{Vector{UInt8}}
    function StringVector{ELT}(
        payloads::Vector{StringPayload},
        buffers::Vector{Vector{UInt8}},
    ) where {ELT}
        _check_string_elt(ELT)
        _validate_column(payloads, buffers, Missing <: ELT, "DataString")
        owned = copy(buffers)
        push!(owned, UInt8[]) # private append-only arena for column edits
        return new{ELT}(payloads, owned)
    end
    function StringVector{ELT}(
        payloads::Vector{StringPayload},
        buffers::Vector{Vector{UInt8}},
        ::Val{:trusted},
    ) where {ELT}
        _check_string_elt(ELT)
        owned = copy(buffers)
        push!(owned, UInt8[]) # private append-only arena for column edits
        return new{ELT}(payloads, owned)
    end
end
_check_string_elt(ELT) =
    (ELT === DataString || ELT === Union{Missing,DataString}) || throw(
        ArgumentError(
            "StringVector element type must be DataString or Union{Missing,DataString}",
        ),
    )
function StringVector{ELT}(
    payloads::Vector{StringPayload},
    buf::Vector{UInt8},
    extra::Vector{UInt8},
) where {ELT}
    return StringVector{ELT}(payloads, Vector{UInt8}[buf, extra])
end

function Base.size(v::StringVector)
    return size(v.payloads)
end
Base.@propagate_inbounds @inline function Base.getindex(
    v::StringVector{ELT},
    i::Int,
) where {ELT}
    @boundscheck checkbounds(v.payloads, i)
    @inbounds p = v.payloads[i]
    len = payloadlength(p)
    len < 0 && return missing
    len <= INLINE_MAX && return _unchecked_datastring(p, EMPTY_BYTES)
    return _unchecked_datastring(p, v.buffers[payloadbufidx(p) + 1])
end
# All-present columns skip the missing branch entirely — the concrete return
# type is what lets access compile down to zero allocations.
Base.@propagate_inbounds @inline function Base.getindex(
    v::StringVector{DataString},
    i::Int,
)
    @boundscheck checkbounds(v.payloads, i)
    @inbounds p = v.payloads[i]
    len = payloadlength(p)
    len <= INLINE_MAX && return _unchecked_datastring(p, EMPTY_BYTES)
    return _unchecked_datastring(p, v.buffers[payloadbufidx(p) + 1])
end

"""
    materialize(v::StringVector) -> Vector{String} or Vector{Union{String,Missing}}

Copy every element out to a plain `String`, detaching the result from the
column's buffers.
"""
function materialize(v::StringVector{ELT}) where {ELT}
    out = Vector{ELT === DataString ? String : Union{String,Missing}}(undef, length(v))
    scratch = Vector{UInt8}(undef, 16)   # inline payloads reconstruct via two word stores
    GC.@preserve scratch begin
        q = pointer(scratch)
        @inbounds for i in eachindex(v.payloads)
            p = v.payloads[i]
            len = payloadlength(p)
            if len < 0
                out[i] = missing
            elseif len <= INLINE_MAX
                unsafe_store!(Ptr{UInt64}(q), htol((p.a >> 32) | (p.b << 32)))
                unsafe_store!(Ptr{UInt64}(q + 8), htol(p.b >> 32))
                out[i] = unsafe_string(q, len)
            else
                src = v.buffers[payloadbufidx(p) + 1]
                GC.@preserve src begin
                    out[i] = unsafe_string(pointer(src, payloadpos(p)), len)
                end
            end
        end
    end
    return out
end

# ---- bytes columns: the same payload machinery for opaque binary values ----

"""
    DataBytes <: AbstractVector{UInt8}

A binary value: its 16-byte payload plus the byte vector a view's content
lives in — the bytes counterpart of [`DataString`](@ref). The payload layout
is Arrow's BinaryView entry, which is byte for byte the StringView layout, so
[`StringPayload`](@ref) serves both. Byte access, comparison, and hashing
do not allocate; hashing and equality agree with `Vector{UInt8}` through the
generic `AbstractArray` definitions. `Vector{UInt8}(b)` copies out. The
two-argument constructor validates the payload and throws `ArgumentError`;
`Val(:unchecked)` is the internal bypass.
"""
struct DataBytes <: AbstractVector{UInt8}
    p::StringPayload
    data::Vector{UInt8}    # dereferenced only when the payload is a view
    function DataBytes(p::StringPayload, data::Vector{UInt8})
        _validate_payload(p, data)
        return new(p, data)
    end
    DataBytes(p::StringPayload, data::Vector{UInt8}, ::Val{:unchecked}) =
        new(p, data)
end

@inline _unchecked_databytes(p::StringPayload, data::Vector{UInt8}) =
    DataBytes(p, data, Val(:unchecked))

Base.size(b::DataBytes) = (Int(payloadlength(b.p)),)
Base.IndexStyle(::Type{DataBytes}) = IndexLinear()
Base.@propagate_inbounds function Base.getindex(b::DataBytes, i::Int)
    @boundscheck checkbounds(b, i)
    len = payloadlength(b.p)
    len <= INLINE_MAX && return _inlinebyte(b.p, i)
    return @inbounds b.data[payloadpos(b.p) + i - 1]
end

# One word compares length + first four bytes; equal inline payloads then
# compare in registers, equal-prefix views memcmp their retained buffers.
function Base.:(==)(x::DataBytes, y::DataBytes)
    x.p.a == y.p.a || return false
    n = payloadlength(x.p)
    n <= INLINE_MAX && return x.p.b == y.p.b
    GC.@preserve x y begin
        return ccall(
            :memcmp,
            Cint,
            (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
            pointer(x.data, payloadpos(x.p)),
            pointer(y.data, payloadpos(y.p)),
            n,
        ) == 0
    end
end

function Base.Vector{UInt8}(b::DataBytes)
    n = Int(payloadlength(b.p))
    out = Vector{UInt8}(undef, n)
    if n > INLINE_MAX
        GC.@preserve b out begin
            unsafe_copyto!(pointer(out), pointer(b.data, payloadpos(b.p)), n)
        end
    else
        @inbounds for i = 1:n
            out[i] = _inlinebyte(b.p, i)
        end
    end
    return out
end
Base.convert(::Type{Vector{UInt8}}, b::DataBytes) = Vector{UInt8}(b)

"""
    BytesVector{ELT}(payloads, buffers::Vector{Vector{UInt8}})
    BytesVector{ELT}(payloads, buffers, Val(:trusted))

A binary column: one payload per element and the byte buffers that view
payloads point into — the bytes counterpart of [`StringVector`](@ref), and an
Arrow BinaryView array's memory. `ELT` is `DataBytes` or
`Union{Missing, DataBytes}`. `getindex` returns an `DataBytes` (or
`missing`) with NO allocation; `materialize` copies out to
`Vector{Vector{UInt8}}`.

Construction validates every payload exactly as [`StringVector`](@ref) does,
and the `Val(:trusted)` constructor skips that validation under the same
contract. Do not resize or mutate the payload vector or any buffer while the
column is in use.
"""
struct BytesVector{ELT} <: AbstractVector{ELT}
    payloads::Vector{StringPayload}
    buffers::Vector{Vector{UInt8}}
    function BytesVector{ELT}(
        payloads::Vector{StringPayload},
        buffers::Vector{Vector{UInt8}},
    ) where {ELT}
        _check_bytes_elt(ELT)
        _validate_column(payloads, buffers, Missing <: ELT, "DataBytes")
        return new{ELT}(payloads, buffers)
    end
    function BytesVector{ELT}(
        payloads::Vector{StringPayload},
        buffers::Vector{Vector{UInt8}},
        ::Val{:trusted},
    ) where {ELT}
        _check_bytes_elt(ELT)
        return new{ELT}(payloads, buffers)
    end
end
_check_bytes_elt(ELT) =
    (ELT === DataBytes || ELT === Union{Missing,DataBytes}) || throw(
        ArgumentError(
            "BytesVector element type must be DataBytes or Union{Missing,DataBytes}",
        ),
    )

Base.size(v::BytesVector) = size(v.payloads)
Base.@propagate_inbounds @inline function Base.getindex(
    v::BytesVector{ELT},
    i::Int,
) where {ELT}
    @boundscheck checkbounds(v.payloads, i)
    @inbounds p = v.payloads[i]
    len = payloadlength(p)
    len < 0 && return missing
    len <= INLINE_MAX && return _unchecked_databytes(p, EMPTY_BYTES)
    return _unchecked_databytes(p, v.buffers[payloadbufidx(p) + 1])
end
# All-present columns skip the missing branch entirely — the concrete return
# type is what lets access compile down to zero allocations.
Base.@propagate_inbounds @inline function Base.getindex(
    v::BytesVector{DataBytes},
    i::Int,
)
    @boundscheck checkbounds(v.payloads, i)
    @inbounds p = v.payloads[i]
    len = payloadlength(p)
    len <= INLINE_MAX && return _unchecked_databytes(p, EMPTY_BYTES)
    return _unchecked_databytes(p, v.buffers[payloadbufidx(p) + 1])
end

"""
    materialize(v::AbstractVector{<:Union{Missing,DataString}}) -> Vector{String} or Vector{Union{String,Missing}}
    materialize(v::AbstractVector{<:Union{Missing,DataBytes}}) -> Vector{Vector{UInt8}} or Vector{Union{Vector{UInt8},Missing}}

Copy every element of a plain vector of values (a column a data source handed out, for
example) out to an owned `String` or `Vector{UInt8}`, detaching the result from the buffers
the values reference; `missing` elements are kept.
"""
materialize(v::AbstractVector{DataString}) = String[String(x) for x in v]
materialize(v::AbstractVector{Union{Missing,DataString}}) =
    Union{String,Missing}[x === missing ? missing : String(x) for x in v]
materialize(v::AbstractVector{DataBytes}) = Vector{UInt8}[Vector{UInt8}(x) for x in v]
materialize(v::AbstractVector{Union{Missing,DataBytes}}) =
    Union{Vector{UInt8},Missing}[x === missing ? missing : Vector{UInt8}(x) for x in v]

"""
    materialize(v::BytesVector) -> Vector{Vector{UInt8}} or Vector{Union{Vector{UInt8},Missing}}

Copy every element out to a plain `Vector{UInt8}`, detaching the result from
the column's buffers.
"""
function materialize(v::BytesVector{ELT}) where {ELT}
    out = Vector{ELT === DataBytes ? Vector{UInt8} : Union{Vector{UInt8},Missing}}(
        undef,
        length(v),
    )
    @inbounds for i in eachindex(v.payloads)
        p = v.payloads[i]
        len = payloadlength(p)
        if len < 0
            out[i] = missing
        else
            b = Vector{UInt8}(undef, len)
            if len <= INLINE_MAX
                for j = 1:len
                    b[j] = _inlinebyte(p, j)
                end
            else
                src = v.buffers[payloadbufidx(p) + 1]
                GC.@preserve src b begin
                    unsafe_copyto!(pointer(b), pointer(src, payloadpos(p)), len)
                end
            end
            out[i] = b
        end
    end
    return out
end

include("construct.jl")

end # module
