using SymbolicRegression
using SymbolicRegression.CoreModule.DatasetModule: get_units
using SymbolicRegression.CheckConstraintsModule: violates_dimensional_constraints
import DynamicQuantities: Quantity, @u_str
using Test
using Random: MersenneTwister

custom_op(x, y) = x + y

options = Options(;
    binary_operators=[-, *, /, custom_op, ^], unary_operators=[cos, cbrt, sqrt, abs]
)
@extend_operators options

(x1, x2, x3) = (i -> Node(Float64; feature=i)).(1:3)

@testset "Dimensional analysis" begin
    X = randn(3, 100)
    y = @. cos(X[3, :] * 2.1 - 0.2) + 0.5

    @test get_units(Float64, [u"m", "1", "kg"]) ==
        [Quantity(1.0; length=1), Quantity(1.0), Quantity(1.0; mass=1)]
    dataset = Dataset(X, y; units=(X=[u"m", u"1", u"kg"], y=u"1"))
    @test dataset.units.X == [Quantity(1.0; length=1), Quantity(1.0), Quantity(1.0; mass=1)]
    @test dataset.units.y == Quantity(1.0)

    violates(tree) = violates_dimensional_constraints(tree, dataset, options)

    good_expressions = [
        Node(; val=3.2),
        3.2 * x1 / x1,
        1.0 * (3.2 * x1 - x2 * x1),
        3.2 * x1 - x2,
        cos(3.2 * x1),
        cos(0.9 * x1 - 0.5 * x2),
        1.0 * (x1 - 0.5 * (x3 * (cos(0.9 * x1 - 0.5 * x2) - 1.2))),
        1.0 * (custom_op(x1, x1)),
        1.0 * (custom_op(x1, 2.1 * x3)),
        1.0 * (custom_op(custom_op(x1, 2.1 * x3), x1)),
        1.0 * (custom_op(custom_op(x1, 2.1 * x3), 0.9 * x1)),
        x2,
        1.0 * x1,
        1.0 * x3,
        (1.0 * x1)^(Node(; val=3.2)),
        1.0 * (cbrt(x3 * x3 * x3) - x3),
        1.0 * (sqrt(x3 * x3) - x3),
        1.0 * (sqrt(abs(x3) * abs(x3)) - x3),
    ]
    bad_expressions = [
        x1,
        x3,
        x1 - x3,
        1.0 * cos(x1),
        1.0 * cos(x1 - 0.5 * x2),
        1.0 * (x1 - (x3 * (cos(0.9 * x1 - 0.5 * x2) - 1.2))),
        1.0 * custom_op(x1, x3),
        1.0 * custom_op(custom_op(x1, 2.1 * x3), x3),
        1.0 * cos(0.8606301 / x1) / cos(custom_op(cos(x1), 3.2263336)),
        1.0 * (x1^(Node(; val=3.2))),
        1.0 * ((1.0 * x1)^x1),
        1.0 * (cbrt(x3 * x3) - x3),
        1.0 * (sqrt(abs(x3)) - x3),
    ]

    for expr in good_expressions
        @test !violates(expr) || @show expr
    end
    for expr in bad_expressions
        @test violates(expr) || @show expr
    end
end

options = Options(; binary_operators=[-, *, /, custom_op], unary_operators=[cos])
@extend_operators options

@testset "Search with dimensional constraints" begin
    X = rand(1, 128) .* 10
    y = @. cos(X[1, :]) + X[1, :]
    dataset = Dataset(X, y; units=(X=["kg"], y="1"))

    hof = EquationSearch(dataset; options)

    # Solutions should be like cos([cons] * X[1]) + [cons]*X[1]
    dominating = calculate_pareto_frontier(hof)
    best_expr = first(filter(m::PopMember -> m.loss < 1e-7, dominating)).tree

    @test !violates_dimensional_constraints(best_expr, dataset, options)
    @test compute_complexity(best_expr, options) >=
        compute_complexity(custom_op(cos(1 * x1), 1 * x1), options)

    # Check that every cos(...) which contains x1 also has complexity 
    has_cos(tree) =
        any(tree) do t
            t.degree == 1 && options.operators.unaops[t.op] == cos
        end
    valid_trees = [
        !has_cos(member.tree) || any(member.tree) do t
            if (
                t.degree == 1 &&
                options.operators.unaops[t.op] == cos &&
                Node(Float64; feature=1) in t
            )
                return compute_complexity(t, options) > 1
            end
            return false
        end for member in dominating
    ]
    @test all(valid_trees)
    @test length(valid_trees) > 0
end

@testset "Search with dimensional constraints on output" begin
    X = randn(2, 128)
    X[2, :] .= X[1, :]
    y = X[1, :] .^ 2

    # The search should find that y=X[2]^2 is the best,
    # due to the dimensionality constraint:
    hof = EquationSearch(X, y; options, units=(X=["kg", u"m"], y="m^2"))

    # Solution should be x2 * x2
    dominating = calculate_pareto_frontier(hof)
    best = first(filter(m::PopMember -> m.loss < 1e-7, dominating)).tree

    @test compute_complexity(best, options) == 3
    @test best.degree == 2
    @test best.l == x2
    @test best.r == x2

    X = randn(2, 128)
    y = @. cbrt(X[1, :]) .+ sqrt(abs(X[2, :]))
    options2 = Options(; binary_operators=[+, *], unary_operators=[sqrt, cbrt, abs])
    hof = EquationSearch(X, y; options=options2, units=(X=["kg^3", "kg^2"], y="kg"))

    dominating = calculate_pareto_frontier(hof)
    best = first(filter(m::PopMember -> m.loss < 1e-7, dominating)).tree
    @test compute_complexity(best, options2) == 6
    @test any(best) do t
        t.degree == 1 && options2.operators.unaops[t.op] == cbrt
    end
    @test any(best) do t
        t.degree == 1 && options2.operators.unaops[t.op] == safe_sqrt
    end
end

@testset "Should warn on non-SI base units" begin
    X = randn(1, 100)
    y = @. cos(X[1, :] * 2.1 - 0.2) + 0.5
    VERSION >= v"1.8.0" && @test_warn(
        "Some of your units are not in their base SI representation.",
        Dataset(X, y; units=(X=[u"m", u"1"], y=u"km"))
    )
end

@testset "Should error on mismatched units" begin
    X = randn(11, 50)
    y = randn(50)
    VERSION >= v"1.8.0" &&
        @test_throws("Number of features", Dataset(X, y; units=(X=["m", "1"], y="kg")))
end
