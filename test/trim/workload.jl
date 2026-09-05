using DataStrings
using DataStrings: StringVector, DataBytes, BytesVector

function (@main)(args::Vector{String})::Cint
    v = StringVector(["tiny", "longer than twelve bytes"])
    x = v[2]
    v[2] = "another long string value"
    push!(v,"more than twelve bytes again")
    x == "longer than twelve bytes" || return 1
    v[1] == "tiny" || return 2
    hash(x) == hash("longer than twelve bytes") || return 3
    cmp(v[1],"tiny") == 0 || return 4
    DataStrings.materialize(v)[2] == "another long string value" || return 5
    bytes = DataBytes(UInt8[1,2,3])
    bytes[2] == 2 || return 6
    Core.println("trim workload passed")
    return 0
end
