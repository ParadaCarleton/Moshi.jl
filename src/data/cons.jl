function _is_doc_macro(head)
    head === Symbol("@doc") && return true
    head isa GlobalRef &&
        head.name === Symbol("@doc") &&
        (head.mod === Core || head.mod === Base) &&
        return true
    return false
end

"""
    order_chain(expr)

Operator (`:<` or `:>`) and operands of an order chain such as `A() < B() < C()`;
`nothing` when `expr` is not an order chain.
"""
function order_chain(expr)
    if Meta.isexpr(expr, :call) && length(expr.args) == 3 && expr.args[1] in (:<, :>)
        return expr.args[1], expr.args[2:3]
    elseif Meta.isexpr(expr, :comparison)
        operators = expr.args[2:2:end]
        all(in((:<, :>)), operators) && allequal(operators) || throw(
            ArgumentError(
                "invalid order chain `$expr`: use only `<` (smallest first) or only `>` (largest first)",
            ),
        )
        return first(operators), expr.args[1:2:end]
    end
    return nothing
end

"""
    push_ordered!(variants, operator, operands, source)

Push the singleton variants of an order chain in source order; return their names from
smallest to largest.
"""
function push_ordered!(variants::Vector{Variant}, operator::Symbol, operands, source)
    names = map(operands) do operand
        Meta.isexpr(operand, :call) &&
            length(operand.args) == 1 &&
            operand.args[1] isa Symbol || throw(
            ArgumentError(
                "invalid order chain operand `$operand`: an order chain holds singleton variants only, written `Name()`",
            ),
        )
        return operand.args[1]
    end
    allunique(names) ||
        throw(ArgumentError("invalid order chain: it names a variant more than once"))
    for name in names
        push!(variants, Variant(Singleton, name, nothing, nothing, source))
    end
    return operator === :< ? names : reverse(names)
end

function push_variants!(variants::Vector{Variant}, expr, doc, source)
    isnothing(order_chain(expr)) || throw(
        ArgumentError(
            "order chain `$expr` must stand alone in the `@data` body, without `@doc` or `begin ... end`",
        ),
    )
    if Meta.isexpr(expr, :macrocall) && _is_doc_macro(expr.args[1])
        non_lnn = filter(a -> !(a isa LineNumberNode), expr.args)
        length(non_lnn) == 3 || throw(
            ArgumentError(
                "malformed @doc in @data body: expected `@doc <docstring> <variant>`, got: $expr",
            ),
        )
        _, doc, variant_expr = non_lnn
        lnn_idx = findfirst(a -> a isa LineNumberNode, expr.args)
        doc_source = isnothing(lnn_idx) ? source : expr.args[lnn_idx]
        push_variants!(variants, variant_expr, doc, doc_source)
        return nothing
    end
    if Meta.isexpr(expr, :block)
        isnothing(doc) || throw(
            ArgumentError(
                "@doc cannot be applied to a block; place `@doc` before each variant individually",
            ),
        )
        for arg in expr.args
            if arg isa LineNumberNode
                source = arg
            elseif !isnothing(arg)
                push_variants!(variants, arg, doc, source)
            end
        end
    else
        push!(variants, Variant(expr; doc, source))
    end
    return nothing
end

# concrete
function TypeDef(
    mod::Module, ismutable::Bool, head, body::Expr; source::LineNumberNode=LineNumberNode(0)
)
    head = TypeHead(head)
    Meta.isexpr(body, :block) ||
        throw(ArgumentError("expect begin ... end block, got $body"))
    variants = Variant[]
    exports = Symbol[]
    order = nothing
    current_line = nothing
    for expr in body.args
        if expr isa LineNumberNode
            current_line = expr
            continue
        elseif isnothing(expr) # sometimes there are generated nothing in the block
            continue
        elseif Meta.isexpr(expr, :export)
            push_exports!(exports, expr)
            continue
        end
        chain = order_chain(expr)
        if isnothing(chain)
            push_variants!(variants, expr, nothing, current_line)
        else
            isnothing(order) || throw(
                ArgumentError("`$(head.name)` has more than one order chain; use one")
            )
            order = push_ordered!(variants, chain..., current_line)
        end
    end
    validate_order(head, ismutable, variants, order)
    validate_exports(head, variants, exports)
    return TypeDef(mod, ismutable, head, variants, exports, source, order)
end

function validate_order(
    head::TypeHead, ismutable::Bool, variants::Vector{Variant}, order::Maybe{Vector{Symbol}}
)
    isnothing(order) && return nothing
    length(order) == length(variants) || throw(
        ArgumentError(
            "the order chain of `$(head.name)` must name every variant; declare all variants in the chain",
        ),
    )
    ismutable &&
        throw(ArgumentError("ordered `@data` type `$(head.name)` cannot be mutable"))
    return nothing
end

function push_exports!(exports::Vector{Symbol}, expr::Expr)
    for name in expr.args
        name isa Symbol || throw(
            ArgumentError(
                "invalid `export` in @data body: expected variant names, got `$expr`"
            ),
        )
        push!(exports, name)
    end
    return nothing
end

function validate_exports(
    head::TypeHead, variants::Vector{Variant}, exports::Vector{Symbol}
)
    variant_names = Set(variant.name for variant in variants)
    for name in exports
        name in variant_names || throw(
            ArgumentError("cannot export `$name`: it is not a variant of `$(head.name)`"),
        )
    end
    return nothing
end

TypeHead(head) = scan_type_head!(TypeHead(), head)

function scan_type_head!(head::TypeHead, head_expr)
    if head_expr isa Symbol
        head.name = head_expr
    elseif Meta.isexpr(head_expr, :curly)
        scan_type_head!(head, head_expr.args[1])
        for arg_expr in head_expr.args[2:end]
            if arg_expr isa Symbol
                push!(head.params, TypeVarExpr(arg_expr))
            elseif Meta.isexpr(arg_expr, :<:)
                arg_expr.args[1] isa Symbol ||
                    throw(ArgumentError("invalid type head expression: $head_expr"))
                push!(head.params, TypeVarExpr(arg_expr.args[1], nothing, arg_expr.args[2]))
            elseif Meta.isexpr(arg_expr, :>:)
                arg_expr.args[1] isa Symbol ||
                    throw(ArgumentError("invalid type head expression: $head_expr"))
                push!(head.params, TypeVarExpr(arg_expr.args[1], arg_expr.args[2], nothing))
            else
                throw(ArgumentError("invalid type head expression: $head_expr"))
            end
        end # for
    elseif Meta.isexpr(head_expr, :<:)
        scan_type_head!(head, head_expr.args[1])
        head.supertype = head_expr.args[2]
    else
        throw(ArgumentError("invalid type head expression: $head_expr"))
    end
    return head
end

function Variant(expr::Symbol; doc=nothing, source=nothing)
    location = source === nothing ? "" : " (near $(source.file):$(source.line))"
    Base.depwarn(
        "the bare singleton variant syntax `$(expr)` is deprecated, " *
        "write `$(expr)()` instead$(location)",
        Symbol("@data");
        force=true,
    )
    return Variant(Singleton, expr, nothing, doc, source)
end

function Variant(expr::Expr; doc=nothing, source=nothing)
    if Meta.isexpr(expr, :call)
        expr.args[1] isa Symbol || throw(ArgumentError("invalid variant expression: $expr"))
        if length(expr.args) == 1
            # explicit singleton form `Name()`
            return Variant(Singleton, expr.args[1], nothing, doc, source)
        end
        return Variant(Anonymous, expr.args[1], Field.(expr.args[2:end]), doc, source)
    elseif Meta.isexpr(expr, :struct)
        jl = JLKwStruct(expr)
        jl.ismutable &&
            throw(ArgumentError("invalid variant expression: $expr, cannot be mutable"))
        isempty(jl.constructors) || throw(
            ArgumentError("invalid variant expression: $expr, cannot have constructors")
        )
        isnothing(jl.supertype) ||
            throw(ArgumentError("invalid variant expression: $expr, cannot have supertype"))
        isempty(jl.typevars) ||
            throw(ArgumentError("invalid variant expression: $expr, cannot have typevars"))
        return Variant(Named, jl.name, NamedField.(jl.fields), doc, source)
    elseif Meta.isexpr(expr, :curly)
        throw(
            ArgumentError(
                "invalid variant expression: $expr, variant cannot have type parameters"
            ),
        )
    else
        throw(ArgumentError("invalid variant expression: $expr"))
    end
end

function NamedField(expr::JLKwField; source=nothing)
    return NamedField(expr.name, expr.isconst, expr.type, expr.default, expr.line)
end
