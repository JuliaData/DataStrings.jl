@testset "constructors and mutable columns" begin
    for str in ("", "hello", "αβγ", "abcdefghijklm", "longer strings stay alive", String(UInt8[0xff,0x80,0x00]))
        s = DataString(str)
        @test String(s) == str
        @test collect(s) == collect(str)
        @test DataString(s) === s
        @test convert(DataString,str) == str
        @test DataString(SubString(str)) == str
        @test Vector{UInt8}(DataBytes(collect(codeunits(str)))) == collect(codeunits(str))
        @test hash(s) == hash(str)
        @test_throws BoundsError iterate(s,0)
    end
    @test match(r"ell",DataString("hello")).match == "ell"
    @test findnext(r"ell",DataString("hello"),1) == 2:4
    @test reverse(DataString("αβ")) == "βα"
    @static if isdefined(Base, :AnnotatedIOBuffer)
        io = Base.AnnotatedIOBuffer()
        @test write(io,DataString("αβ")) == 4
        seekstart(io)
        @test read(io,String) == "αβ"
    end
    @test DataString["a","b"] == ["a","b"]
    values = Union{String,Missing}["a", "a long value retained by a view", missing]
    col = StringVector(values)
    retained = col[2]
    @test isequal(AS.materialize(col),values)
    col[2] = "replacement that needs a retained buffer"
    @test retained == values[2]
    saved = col[2]
    for i in 1:1000
        push!(col,"append $i with enough bytes to cause arena growth")
    end
    @test saved == "replacement that needs a retained buffer"
    col[1] = saved
    @test col[1] == saved
    duplicate = copy(col)
    empty!(col)
    @test saved == duplicate[2]
    push!(col,"new bytes after emptying the column")
    @test saved == duplicate[2]
    @test length(col) == 1
    @test_throws ArgumentError push!(StringVector(["x"]),missing)
    plain = StringVector(["a","b"])
    resize!(plain,4)
    @test AS.materialize(plain) == ["a","b","",""]
    nullable = StringVector(Union{Missing,String}["a"])
    resize!(nullable,3)
    @test isequal(AS.materialize(nullable),["a",missing,missing])
    @test_throws BoundsError plain[0] = "x"
    @test_throws ArgumentError resize!(plain,-1)
    rng = MersenneTwister(81)
    oracle = Union{Missing,String}[]
    v = StringVector(oracle)
    for i in 1:1000
        str = rand(rng) < 0.2 ? missing : randstring(rng,rand(rng,0:40))
        if isempty(oracle) || rand(rng) < 0.5
            push!(oracle,str); push!(v,str)
        else
            j = rand(rng,eachindex(oracle))
            oracle[j] = str; v[j] = str
        end
        @test isequal(AS.materialize(v),oracle)
    end
    @test isequal(pop!(v),pop!(oracle))
    @test isequal(popfirst!(v),popfirst!(oracle))
    pushfirst!(v,"front");pushfirst!(oracle,"front")
    insert!(v,2,"middle");insert!(oracle,2,"middle")
    deleteat!(v,3);deleteat!(oracle,3)
    keepat!(v,1:2);keepat!(oracle,1:2)
    @test isequal(AS.materialize(v),oracle)
    @test isempty(Test.detect_ambiguities(DataStrings, Base; recursive=true))
end
