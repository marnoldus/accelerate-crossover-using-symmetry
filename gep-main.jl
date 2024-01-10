## Generation expansion planning (GEP)

const CONFIG_FILE_NAME        = "config.toml"
const VISUALIZATION_FILE_NAME = "visualization.toml"

const HIGHS  = "HiGHS"
const GUROBI = "Gurobi"
const CPLEX_NAME = "CPLEX"
const SCIP_NAME = "SCIP"

include("logging.jl")
## Step 0: Activate environment - ensure consistency accross computers
print_message("Reading the data", level=1)
print_message("Activating the environment", level=2)

using Pkg
Pkg.activate(@__DIR__) # @__DIR__ = directory this script is in
Pkg.instantiate() # Download and install this environments packages
Pkg.precompile() # Precompiles all packages in environemt

using DataFrames
using CSV
using TimerOutputs

print_message("Including the external scripts")

include("gep-config-parser.jl")
include("data-wrangling.jl")
include("plotting-functions.jl")
include("symmetry_handling/symmetry1.jl")
include("symmetry_handling/symmetry2.jl")

# @time begin
##  Step 1: Parse the input data
print_message("Parsing the config file")

data = parse_config(CONFIG_FILE_NAME)
experiment = data[:experiment]
# inputs = data[:inputs]
outputs_config = data[:outputs_config]


# Select solver to be used.
print_message("Initializing the solver", level=2)
optimizer_name = data[:optimizer_config][:solver] 

optimizer = if optimizer_name == HIGHS
    using HiGHS
    print_message("Using $HIGHS")
    HiGHS.Optimizer
elseif optimizer_name == GUROBI
    using Gurobi
    print_message("Using $GUROBI")
    Gurobi.Optimizer
elseif optimizer_name == CPLEX_NAME 
    using CPLEX
    CPLEX.Optimizer
elseif optimizer_name == SCIP_NAME
    using SCIP
    SCIP.Optimizer
else
    throw(DomainError(solver, SOLVER_UNSUPPORTED_MESSAGE))
end


function run_model(inputs)
    # Runs one experiment using the specified inputs.

    if outputs_config[:terminal][:input_plots]
        print_message("Input data statistics", level=2)
        visualization_data = get_visualization_data(VISUALIZATION_FILE_NAME)
        print_input_statistics(inputs, visualization_data)
    end

    ## Step 2: Wrangle the data
    print_message("Wrangling the input data")

    # Extract sets
    global T = inputs[:times]
    global G = inputs[:generators]
    global L = inputs[:transmission_lines]
    global N = inputs[:nodes]

    # Extract time series data
    global pDemand = dataframe_to_dict(
        inputs[:demand_data],
        [:Country, :Time],
        :Demand_MW
    )
    global pGenAva = dataframe_to_dict(
        inputs[:generation_availability_data],
        [:Country, :Technology, :Time],
        :Availability_pu
    )

    # Extract scalar parameters
    global pVOLL   = inputs[:value_of_lost_load] 
    global pWeight = inputs[:representative_period_weight]
    global pRamping = inputs[:ramping_value]

    # Extract generator parameters
    global pInvCost = dataframe_to_dict(
        inputs[:generation_data],
        [:Country, :Technology],
        :InvCost_kEUR_MW_year
    )
    global pVarCost = dataframe_to_dict(
        inputs[:generation_data],
        [:Country, :Technology],
        :VarCost_kEUR_per_MWh
    )
    global pUnitCap = dataframe_to_dict(
        inputs[:generation_data],
        [:Country, :Technology],
        :UnitCap_MW
    )

    # Extract line parameters
    global pExpCap = dataframe_to_dict(
        inputs[:transmission_lines_data],
        [:CountryA, :CountryB],
        :ExpCap_MW
    )
    global pImpCap = dataframe_to_dict(
        inputs[:transmission_lines_data],
        [:CountryA, :CountryB],
        :ImpCap_MW
    )

    ## Step 3: Construct the model
    print_message("Constructing the model", level=1)

    # Initialise solver attraibutes.
    attributes = data[:optimizer_config][Symbol(optimizer_name)] 

    attributes = merge(attributes, Dict("LogFile" => inputs[:output_log] ))
    m = initialize_model(optimizer, attributes)

    # If symmetry method s2 is used, run that file, else solve the regular problem.
    if (inputs[:symmetry] == "s2")
        res, setup_time, restore_time = solveS2(m, inputs[:ramping])
        return res, setup_time, restore_time
    else
        t_start = time_ns()
        # Reduce number of generators if s1 is applied.
        if inputs[:symmetry] == "s1"
            G = reduceS1(G, pUnitCap, pInvCost, pVarCost, pGenAva)
        end
        
        print_message("Populating the model", level=2)

        # Create variables
        print_message("Adding model variables")
        @variable(m,           0 ≤ vInvCost)
        @variable(m,           0 ≤ vOpeCost)
        if inputs[:relaxed] == "true"
            @variable(m,           0 ≤ vGenInv[G]) 
        else
            @variable(m,           0 ≤ vGenInv[G], Int)
        end
        @variable(m,           0 ≤ vGenProd[G, T])
        @variable(m, -pImpCap[l] ≤ vLineFlow[l in L, T]      ≤ pExpCap[l])
        @variable(m,           0 ≤ vLossLoad[n in N, t in T] ≤ pDemand[(n, t)])

        # Formulate objective
        print_message("Formulating the objective")
        @objective(m, Min, vInvCost + vOpeCost)

        # constraints
        print_message("Adding model constraints")
        # eInvCost
        @constraint(m,
            vInvCost == sum(pInvCost[g] * pUnitCap[g] * vGenInv[g] for g in G)
        )

        # eOpeCost
        @constraint(m,
            vOpeCost == pWeight * (
                sum(pVarCost[g] *  vGenProd[g, t] for g in G, t in T)
            + sum(pVOLL       * vLossLoad[n, t] for n in N, t in T)
            )
        )

        # eNodeBal
        @constraint(m, λ[n in N, t in T],
            (sum( vGenProd[g, t] for g in G if g[1] == n) 
            + sum(vLineFlow[l, t] for l in L if l[2] == n) 
            - sum(vLineFlow[l, t] for l in L if l[1] == n)
            + vLossLoad[n, t]
            ==
            pDemand[(n, t)])
        )

        # eMaxProd
        # for technologies without the availability profile, the availability is 
        # always equal to 100%, that is, 1.0. This is why we use
        # get(pGenAva, (g..., t), 1.0) and not pGenAva[g..., t]
        @constraint(m, [g in G, t in T], vGenProd[g, t] <= get(pGenAva, (g..., t), 1.0) * pUnitCap[g] * vGenInv[g]
        )

        # Ramping constraints needs to go here. The idea is that the production in two
        # consecutive time steps cannot differ by more than some scalar amount (e.g.,
        # 0.2 or 20% of the maximum production defined as pUnitCap * vGenInv). This new
        # parameter should go into /inputs/scalars.toml.
        if inputs[:ramping] == "true"
            # eRampingUp
            @constraint(m, [g in G, t in T[2:length(T)]], vGenProd[g, t] - vGenProd[g, t-1] ≤ pRamping * pUnitCap[g] * vGenInv[g]
            )
            # eRampingDown
            @constraint(m, [g in G, t in T[2:length(T)]], -pRamping * pUnitCap[g] * vGenInv[g] <= vGenProd[g, t] - vGenProd[g, t-1]
            )
        end
        
        # Compute time for setting up constraints and variables.
        setup_time = time_ns() - t_start

        ## Step 4: Solve
        print_message("Solving the optimization problem", level=1)
        
        optimize!(m)

        if outputs_config[:terminal][:solution_summary]
            print_message("Solution summary", level=2)
            println(solution_summary(m))
        end

        print_message("Elapsed time", level=2)
        
        # If s1 is used, restore solution to original problem and compute unfolding time.
        if inputs[:symmetry] == "s1"
            t1 = time_ns()
            vGenInv, vGenProd = restoreS1(m)
            restore_time = time_ns() - t1
        else
            restore_time = 0
        end

        # ## Step 5: Interpret the results

        # variables/expressions
        if input[:symmetry] == "none"
            vGenInv_df = jump_container_to_df(value.(vGenInv); dim_names=[(:Country, :Technology)])
            # vGenInv_df = leftjoin(
            #         vGenInv_df,
            #         inputs[:generation_data][!, [:Country, :Technology, :UnitCap_MW]], 
            #         on=[:Country, :Technology]
            #     )
            # vGenInv_df.Value = vGenInv_df.Value .* vGenInv_df.UnitCap_MW
            # select!(vGenInv_df, Not(:UnitCap_MW))

            vGenProd_df = jump_container_to_df(value.(vGenProd); dim_names=[(:Country, :Technology), :Time])

            outputs = Dict(
                :vGenInv  => vGenInv_df,
                :vGenProd => vGenProd_df
            )

            if has_duals(m)
                outputs[:λ] = jump_container_to_df(dual.(λ); dim_names=[:Country, :Time])
            end

            if outputs_config[:terminal][:output_plots]
                print_message("Outputs statistics", level=2)
                if visualization_data ≡ nothing
                    visualization_data = get_visualization_data(VISUALIZATION_FILE_NAME)
                end
                print_output_statistics(outputs, visualization_data)
            end

            if outputs_config[:plots]
                print_message("Plotting the results", level=2)
                plot_outputs(outputs, inputs)
            end
        end

        return m, setup_time, restore_time
    end

    
end

function check_feasibility(result)
    if !isapprox(result[name(model[:vInvCost])], sum(pInvCost[g] * pUnitCap[g] * result[name(model[:vGenInv][g])] for g in G), atol=1e-5)
        println("InvCost")
        return false
    end
    if !isapprox(result[name(model[:vOpeCost])],
        pWeight * (sum(pVarCost[g] *  result[name(model[:vGenProd][g, t])] for g in G, t in T) 
        + sum(pVOLL * result[name(model[:vLossLoad][n, t])] for n in N, t in T)), atol=1e-5)
        println("OpeCost")
        println(result[name(model[:vOpeCost])])
        println(pWeight * (sum(pVarCost[g] *  result[name(model[:vGenProd][g, t])] for g in G, t in T) 
        + sum(pVOLL * result[name(model[:vLossLoad][n, t])] for n in N, t in T)))
        return false
    end
    for n in N
        for t in T
            if pDemand[(n, t)] - 1e-5 > (sum( result[name(model[:vGenProd][g, t])] for g in G if g[1] == n)
                + sum((result[name(model[:vLineFlow][l, t])] for l in L if l[2] == n), init=0.0)
                - sum((result[name(model[:vLineFlow][l, t])] for l in L if l[1] == n), init=0.0)
                + result[name(model[:vLossLoad][n, t])])
                println("eNodeBal")
                println(pDemand[(n, t)])
                println(pDemand[(n, t)] - 1e-5)
                println(sum( result[name(model[:vGenProd][g, t])] for g in G if g[1] == n)
                + sum((result[name(model[:vLineFlow][l, t])] for l in L if l[2] == n), init=0.0)
                - sum((result[name(model[:vLineFlow][l, t])] for l in L if l[1] == n), init=0.0)
                + result[name(model[:vLossLoad][n, t])])
                return false
            end
        end
    end
    for g in G
        for t in T
            if result[name(model[:vGenProd][g, t])] > get(pGenAva, (g..., t), 1.0) * pUnitCap[g] * result[name(model[:vGenInv][g])]
                println("GenProd")
                return false
            end
        end
    end
    for g in G
        for t in T[2:length(T)]
            if result[name(model[:vGenProd][g, t])] - result[name(model[:vGenProd][g, t-1])] > pRamping * pUnitCap[g] * result[name(model[:vGenInv][g])]
                println("RampingUp")
                return false
            end
            if -pRamping * pUnitCap[g] * result[name(model[:vGenInv][g])] > result[name(model[:vGenProd][g, t])] - result[name(model[:vGenProd][g, t-1])]
                println("RampingDown")
                return false
            end
        end
    end
    return true
end


function run_fixed_investments(result)
    attributes = data[:optimizer_config][Symbol(optimizer_name)] 
    attributes = merge(attributes, Dict("LogFile" => inputs[:output_log] ))
    m_inv = initialize_model(optimizer, attributes)

    print_message("Populating the model", level=2)

    # Create variables
    print_message("Adding model variables")
    @variable(m_inv,           0 ≤ vOpeCost)
    @variable(m_inv,           0 ≤ vGenProd[G, T])
    @variable(m_inv, -pImpCap[l] ≤ vLineFlow[l in L, T]      ≤ pExpCap[l])
    @variable(m_inv,           0 ≤ vLossLoad[n in N, t in T] ≤ pDemand[(n, t)])

    # Formulate objective
    print_message("Formulating the objective")
    @objective(m_inv, Min, vOpeCost)

    # constraints
    print_message("Adding model constraints")

    # eOpeCost
    @constraint(m_inv,
        vOpeCost == pWeight * (
            sum(pVarCost[g] *  vGenProd[g, t] for g in G, t in T)
        + sum(pVOLL       * vLossLoad[n, t] for n in N, t in T)
        )
    )

    # eNodeBal
    @constraint(m_inv, λ[n in N, t in T],
        sum( vGenProd[g, t] for g in G if g[1] == n)
        + sum(vLineFlow[l, t] for l in L if l[2] == n)
        - sum(vLineFlow[l, t] for l in L if l[1] == n)
        + vLossLoad[n, t]
        ==
        pDemand[(n, t)]
    )

    # eMaxProd
    # for technologies without the availability profile, the availability is 
    # always equal to 100%, that is, 1.0. This is why we use
    # get(pGenAva, (g..., t), 1.0) and not pGenAva[g..., t]
    @constraint(m_inv, [g in G, t in T],
        vGenProd[g, t] <=
            get(pGenAva, (g..., t), 1.0) * pUnitCap[g] * result[name(model[:vGenInv][g])]
    )

    # Ramping constraints needs to go here. The idea is that the production in two
    # consecutive time steps cannot differ by more than some scalar amount (e.g.,
    # 0.2 or 20% of the maximum production defined as pUnitCap * vGenInv). This new
    # parameter should go into /inputs/scalars.toml.
    if inputs[:ramping] == "true"
        # eRampingUp
        @constraint(m_inv, [g in G, t in T[2:length(T)]],
            vGenProd[g, t] - vGenProd[g, t-1] ≤ pRamping * pUnitCap[g] * result[name(model[:vGenInv][g])]
        )
        # eRampingDown
        @constraint(m_inv, [g in G, t in T[2:length(T)]],
            -pRamping * pUnitCap[g] * result[name(model[:vGenInv][g])] <= vGenProd[g, t] - vGenProd[g, t-1]
        )
    end

    ## Step 4: Solve
    print_message("Solving the optimization problem", level=1)
    optimize!(m)
 
    # print some output
    if outputs_config[:terminal][:solution_summary]
        print_message("Solution summary", level=2)
        println(solution_summary(m))
    end
 
    print_message("Elapsed time", level=2)
end

# Main loop for running experiments
for i in eachindex(experiment[:experiments])
    # Setup output dataframe. Note that presolve, barrier and crossover times cannot be computed from code, so these are in the logs.
    df_res = DataFrame(setup_time = [], presolve_time = [], barrier_time = [], crossover_time = [], restore_time = [], objective_value = [])
    for j in 1:experiment[:repeats]
        # Run one experiment for j repeats.
        res, setup_time, restore_time = run_model(experiment[:experiments][i])
        if experiment[:experiments][i][:symmetry] == "s2"
            append!(df_res, DataFrame(setup_time = [setup_time], presolve_time = ["-"], barrier_time = ["-"], crossover_time = ["-"], restore_time = [restore_time], objective_value = [res.invCost + res.opeCost]))
        else
            append!(df_res, DataFrame(setup_time = [setup_time], presolve_time = ["-"], barrier_time = ["-"], crossover_time = ["-"], restore_time = [restore_time], objective_value = [objective_value(res)]))
        end
        model = Nothing
    end
    # Write dataframe to csv.
    CSV.write(experiment[:experiments][i][:output_file], df_res)
end

