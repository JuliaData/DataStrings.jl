# Serialize a DataString or DataBytes as a copy that owns only its own bytes.
# The default field-by-field serialization writes the whole retained buffer, and
# a value read from a file can retain a buffer as large as the file. This is
# the same treatment Serialization gives `SubString{String}`.
module DataStringsSerializationExt

using DataStrings: DataString, DataBytes, INLINE_MAX, EMPTY_BYTES, payloadlength,
    payloadpos, view_payload
using Serialization: Serialization, AbstractSerializer

# The same value with a retained vector holding exactly its bytes; an inline
# value's payload already holds them.
function _owned(x::T) where {T<:Union{DataString,DataBytes}}
    n = Int(payloadlength(x.p))
    n <= INLINE_MAX && return T(x.p, EMPTY_BYTES, Val(:unchecked))
    first = payloadpos(x.p)
    data = x.data[first:(first + n - 1)]
    return T(view_payload(data, 1, n, 0, 0), data, Val(:unchecked))
end

Serialization.serialize(s::AbstractSerializer, x::Union{DataString,DataBytes}) =
    Serialization.serialize_any(s, _owned(x))

end # module
