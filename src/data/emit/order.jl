module Order

using ..Data: @pass, Data, EmitInfo
using ExproniconLite: JLIfElse, codegen_ast

const RANK = Symbol("##rank")

# `Base.isless` for a type with an order chain: variants compare by chain position.
@pass function emit_isless(info::EmitInfo)
    order = info.def.order
    isnothing(order) && return nothing
    jl = JLIfElse()
    for storage in info.storages
        jl[:(data isa $(storage.name))] = findfirst(==(storage.parent.name), order)
    end
    jl.otherwise = quote
        $Base.error("unreachable reached")
    end

    return quote
        function $RANK(value::Type)
            data = $Base.getfield(value, :data)
            return $(codegen_ast(jl))
        end

        $Base.isless(lhs::Type, rhs::Type) = $Base.isless($RANK(lhs), $RANK(rhs))
    end
end

end # Order
