using Serialization

function serialized(x)
    io = IOBuffer()
    serialize(io, x)
    return deserialize(seekstart(io)), position(io)
end

@testset "Serialization writes a value's own bytes" begin
    buf = Vector{UInt8}(repeat("0123456789", 100_000))
    long = DataString(AS.view_payload(buf, 11, 20, 0, 10), buf)
    short = StringVector(["short"])[1]
    bytes = DataBytes(AS.view_payload(buf, 1, 40, 0, 0), buf)
    malformed = DataString("\xff\xfe malformed UTF-8 \xc0")
    for x in (long, short, DataString("not retained: built from a String"), malformed, bytes)
        y, n = serialized(x)
        @test typeof(y) == typeof(x) && y == x && hash(y) == hash(x)
        # the value's bytes plus type tags, never the 1 MB retained buffer
        @test n < 200
    end
    y, _ = serialized(long)
    @test y.data !== buf && length(y.data) == ncodeunits(long)

    # values inside containers, and columns (which keep their own layout)
    y, n = serialized(Union{Missing,DataString}[long, missing, short])
    @test isequal(y, [long, missing, short]) && n < 400
    col = StringVector(["short", "a longer string value"])
    y, _ = serialized(col)
    @test y isa StringVector{DataString} && y == col
    y, _ = serialized(Dict(long => 1))
    @test y == Dict(long => 1)
end
