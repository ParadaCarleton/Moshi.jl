using Test
using Moshi.Data: @data, TypeDef, variants
using Moshi.Match: @match

@data Tier begin
    Safe() < Likely() < Breaking() < Manual()
end

@data Priority begin
    High() > Medium() > Low()
end

@data Switch begin
    export Off, On

    Off() < On()
end

@data Plain begin
    A()
    B()
end

tier_rank(tier::Tier.Type) = @match tier begin
    Tier.Safe() => 1
    Tier.Likely() => 2
    Tier.Breaking() => 3
    Tier.Manual() => 4
end

@testset "ascending chain" begin
    @test Tier.Safe() < Tier.Likely() < Tier.Breaking() < Tier.Manual()
    @test !(Tier.Manual() < Tier.Safe())
    @test !isless(Tier.Likely(), Tier.Likely())
    @test isequal(Tier.Likely(), Tier.Likely())
    @test max(Tier.Safe(), Tier.Breaking()) == Tier.Breaking()
    @test sort([Tier.Manual(), Tier.Safe(), Tier.Breaking()]) ==
        [Tier.Safe(), Tier.Breaking(), Tier.Manual()]
    @test cmp(Tier.Manual(), Tier.Likely()) == 1
    @test variants(Tier.Type) == (Tier.Safe, Tier.Likely, Tier.Breaking, Tier.Manual)
    @test map(tier_rank, sort([Tier.Manual(), Tier.Likely()])) == [2, 4]
end

@testset "descending chain" begin
    @test Priority.Low() < Priority.Medium() < Priority.High()
    @test maximum([Priority.Low(), Priority.High(), Priority.Medium()]) == Priority.High()
    @test variants(Priority.Type) == (Priority.High, Priority.Medium, Priority.Low)
end

@testset "two-variant chain with export" begin
    @test Switch.Off() < Switch.On()
    @test Base.isexported(Switch, :On)
end

@testset "no chain, no order" begin
    @test !hasmethod(isless, Tuple{Plain.Type,Plain.Type})
end

function order_error(body::Expr; ismutable::Bool=false)
    try
        TypeDef(@__MODULE__, ismutable, :Bad, body)
        nothing
    catch error
        error isa ArgumentError || rethrow()
        error.msg
    end
end

@testset "invalid chains" begin
    @test occursin("only `<`", order_error(:(
        begin
            A() < B() > C()
        end
    )))
    @test occursin("only `<`", order_error(:(
        begin
            A() < B() <= C()
        end
    )))
    @test occursin("only `<`", order_error(:(
        begin
            A() == B() == C()
        end
    )))
    @test occursin("written `Name()`", order_error(:(
        begin
            A < B
        end
    )))
    @test occursin("singleton variants only", order_error(:(
        begin
            A() < B(Int)
        end
    )))
    @test occursin("more than once", order_error(:(
        begin
            A() < B() < A()
        end
    )))
    @test occursin("must name every variant", order_error(:(
        begin
            A() < B()
            C()
        end
    )))
    @test occursin("more than one order chain", order_error(:(
        begin
            A() < B()
            C() < D()
        end
    )))
    @test occursin("cannot be mutable", order_error(:(
        begin
            A() < B()
        end
    ); ismutable=true))
    @test occursin("must stand alone", order_error(:(
        begin
            begin
                A() < B()
            end
        end
    )))
    @test occursin("must stand alone", order_error(:(
        begin
            @doc "doc" A() < B()
        end
    )))
end
