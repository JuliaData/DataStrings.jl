# Construction and column editing adapted from the CSV CompactString work.
# Existing buffers are borrowed; edits append to the column's private arena.

"""
    DataString(s::AbstractString)

Copy a string into an inline payload (up to 12 UTF-8 bytes) or a retained
private byte buffer. Constructing from another `DataString` returns it unchanged.
"""
function DataString(s::AbstractString)
    bytes = codeunits(String(s))
    n = length(bytes)
    n <= INLINE_MAX && return _unchecked_datastring(inline_payload(bytes, 1, n), EMPTY_BYTES)
    data = Vector{UInt8}(bytes)
    return _unchecked_datastring(view_payload(data, 1, n, 0, 0), data)
end

DataString(s::DataString) = s
Base.convert(::Type{DataString}, s::AbstractString) = DataString(s)
Base.match(r::Regex, s::DataString, i::Integer=1, options::UInt32=UInt32(0)) = match(r, String(s), i, options)
Base.findnext(r::Regex, s::DataString, i::Integer) = findnext(r, String(s), i)
Base.reverse(s::DataString) = reverse(String(s))

@static if isdefined(Base, :AnnotatedIOBuffer)
    Base.write(io::Base.AnnotatedIOBuffer, s::DataString) = write(io, String(s))
end

"""
    DataStrings.DataBytes(bytes::AbstractVector{UInt8})

Copy bytes into an inline payload or a retained private buffer.
"""
function DataBytes(bytes::AbstractVector{UInt8})
    data = collect(bytes)
    n = length(data)
    n <= INLINE_MAX && return _unchecked_databytes(inline_payload(data, 1, n), EMPTY_BYTES)
    return _unchecked_databytes(view_payload(data, 1, n, 0, 0), data)
end

DataBytes(bytes::DataBytes) = bytes
Base.convert(::Type{DataBytes}, bytes::AbstractVector{UInt8}) = DataBytes(bytes)
Base.convert(::Type{DataBytes}, bytes::DataBytes) = bytes

function _append_value!(v::StringVector, s::AbstractString)
    n = ncodeunits(s)
    n <= INLINE_MAX && return inline_payload(codeunits(s), 1, n)
    arena = v.buffers[end]
    off = length(arena)
    n <= typemax(Int32) - off || throw(ArgumentError("string column arena exceeds 2 GiB; materialize the column"))
    length(v.buffers) - 1 <= typemax(Int32) || throw(ArgumentError("too many string buffers"))
    resize!(arena, off+n)
    @inbounds for i in 1:n
        arena[off+i] = codeunit(s,i)
    end
    return view_payload(arena, off+1, n, length(v.buffers)-1, off)
end

function _payloadfor!(v::StringVector, s::DataString)
    n = ncodeunits(s)
    n <= INLINE_MAX && return s.p
    for i in eachindex(v.buffers)
        v.buffers[i] === s.data && return StringPayload(s.p.a, _viewword(i-1, payloadoffset(s.p)))
    end
    return _append_value!(v,s)
end

_payloadfor!(v::StringVector, s::AbstractString) = _append_value!(v,s)
function _payloadfor!(::StringVector{ELT}, ::Missing) where {ELT}
    Missing <: ELT || throw(ArgumentError("this string column does not accept missing"))
    return PAYLOAD_MISSING
end

"""
    DataStrings.StringVector(values::AbstractVector)
    DataStrings.StringVector{ELT}(values::AbstractVector)

Build a mutable string column. `ELT` is `DataString` or
`Union{Missing,DataString}`. New long strings are copied into an append-only
arena. Previously returned values stay valid after edits, removal, or resizing.
Deleted bytes are retained until all owners are collected; `materialize` copies
live values out. Concurrent mutation requires external synchronization.
"""
function StringVector{ELT}(values::AbstractVector) where {ELT}
    v = StringVector{ELT}(StringPayload[], Vector{UInt8}[])
    sizehint!(v,length(values))
    for x in values
        push!(v,x)
    end
    return v
end

StringVector(values::AbstractVector) = StringVector{Missing <: eltype(values) ? Union{Missing,DataString} : DataString}(values)
Base.IndexStyle(::Type{<:StringVector}) = IndexLinear()

Base.@propagate_inbounds function Base.setindex!(v::StringVector, x, i::Int)
    @boundscheck checkbounds(v.payloads,i)
    @inbounds v.payloads[i] = _payloadfor!(v,x)
    return v
end

Base.push!(v::StringVector,x) = (push!(v.payloads,_payloadfor!(v,x)); v)
Base.pushfirst!(v::StringVector,x) = (pushfirst!(v.payloads,_payloadfor!(v,x)); v)
Base.insert!(v::StringVector,i::Integer,x) = (insert!(v.payloads,i,_payloadfor!(v,x)); v)
Base.deleteat!(v::StringVector,i) = (deleteat!(v.payloads,i); v)
Base.keepat!(v::StringVector,i) = (keepat!(v.payloads,i); v)
Base.empty!(v::StringVector) = (empty!(v.payloads); v)
Base.sizehint!(v::StringVector,n::Integer) = (sizehint!(v.payloads,n); v)

function Base.pop!(v::StringVector)
    x = v[end]
    pop!(v.payloads)
    return x
end

function Base.popfirst!(v::StringVector)
    x = v[1]
    popfirst!(v.payloads)
    return x
end

function Base.resize!(v::StringVector{ELT}, n::Integer) where {ELT}
    old = length(v)
    resize!(v.payloads,n)
    initial = Missing <: ELT ? PAYLOAD_MISSING : StringPayload(0,0)
    @inbounds for i in old+1:n
        v.payloads[i] = initial
    end
    return v
end

Base.copy(v::StringVector{ELT}) where {ELT} = StringVector{ELT}(copy(v.payloads),v.buffers)
Base.convert(::Type{Vector{String}}, v::StringVector{DataString}) = materialize(v)
Base.convert(::Type{Vector{Union{String,Missing}}}, v::StringVector) = convert(Vector{Union{String,Missing}}, materialize(v))
