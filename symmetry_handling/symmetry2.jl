using Formatting
using Combinatorics
using Random

# Struct representing a solution to the original problem.
mutable struct Solution
    invCost
    opeCost
    genInv
    genProd
    lossLoad
    lineFlow
end

# Used arrays and dictionaries.
subnodes = Dict()
supernodes = []
reduced_nodes = []
reduced_lines = []
producing_generators = []
subgenerators = Dict()

# Function for checking if two nodes are connected directly by an edge.
function isConnected(n1, n2)
    # Loop over all lines and if it connects n1 and n2 return true.
    for l in L
        if l[1] == n1 && l[2] == n2 || l[1] == n2 && l[2] == n1
            return true
        end
    end
    # Return false otherwise.
    return false
end

function getGeneratorsByNode(n)
    # Get original generators of node n.
    generators = []
    for g in G
        if g[1] == n
            push!(generators, g)
        end
    end
    return generators
end

function getGeneratorsOfNewNode(n)
    # Loop over all generators to find all new generators of a merged node.
    generators = []
    for g in producing_generators
        if g[1] == n
            push!(generators, g)
        end
    end
    return generators
end

function getEqualGenerators(n1, n2)
    # Initialise parameters and arrays.
    gen1 = getGeneratorsByNode(n1)
    gen2 = getGeneratorsByNode(n2)
    reduced_gen2 = []
    pairs = []
    singles = []
    reduced = false

    # Shuffle the sets of generators to generate an arbitrary order in which they are compared.
    shuffle(gen1)
    shuffle(gen2)

    # Loop over all generators in n1 and compare to other generators to find out if they are symmetric.
    for g1 in gen1
        # If a pair has already been found, put all other generators in the singles array.
        if reduced
            push!(singles, g1)
            continue
        end
        # Loop over all generators of node n2 to see if they are symmetric to g1.
        for g2 in gen2
            if g2 in reduced_gen2
                continue
            end
            if pUnitCap[g1] == pUnitCap[g2] && pInvCost[g1] == pInvCost[g2] && pVarCost[g1] == pVarCost[g2] 
                push!(pairs, (g1,g2))
                push!(reduced_gen2, g2)
                reduced = true
                break
            end
        end
        if !reduced
            push!(singles, g1)
        end
    end
    for g2 in gen2
        if !(g2 in reduced_gen2)
            push!(singles, g2)
        end
    end
    return pairs, singles
end

function getLineBetween(n1, n2)
    # Loop over all transmission lines to find the line between n1 and n2.
    for l in L
        if (l[1] == n1 && l[2] == n2) || (l[1] == n2 && l[2] == n1)
            return l
        end
    end
    return false
end

function getCapFromTo(from, to)
    # Get import or export capacity of a line from a to b.
    for l in L
        if l[1] == from && l[2] == to
            return pExpCap[l]
        end
        if l[1] == to && l[2] == from
            return pImpCap[l]
        end
    end
    return 0
end

function getGeneratorOrSub(g)
    # If g has no subplant, return g, else return its subplant.
    if g in G 
        return g
    else 
        return subgenerators[g][1]
    end
end

function reduceS2(m)
    # Randomly permute the set of nodes, then loop over all nodes in the new order.
    shuffle!(N)
    for n1 in N
        # If n1 already reduced into another node, continue.
        if n1 in reduced_nodes
            continue
        end
        # Loop over all nodes to check if they are symmetric to n1.
        for n2 in N
            # If n1 and n2 equal or not connected, or n2  has already been merged with another node, continue.
            if n1 == n2 || n2 in reduced_nodes || !isConnected(n1, n2)
                continue
            end
            # Get nodes to be merged in n1 and n2, merge them and add all variables and constraints to the model.
            pairs, singles = getEqualGenerators(n1, n2)
            
            # If plants can be merged, merge them. 
            if !isempty(pairs)
                # Create new node out of n1 and n2
                newNode = n1 * n2
                push!(supernodes, newNode)
                subnodes[newNode] = [n1, n2]
                append!(reduced_nodes, [n1,n2])

                # Generate new merged plant.
                newGenerators = []
                for (g1, g2) in pairs
                    newGenerator = (newNode, g1[2])
                    push!(newGenerators, newGenerator)
                    subgenerators[newGenerator] = [g1, g2]
                end
                
                # For plants that are not merged, simply assign them to the new node.
                for g in singles
                    newGenerator = (newNode, g[2] * g[1])
                    push!(newGenerators, newGenerator)
                    subgenerators[newGenerator] = [g]
                end
                append!(producing_generators, newGenerators)
                push!(reduced_lines, getLineBetween(n1, n2))
            end
        end
        # If n1 not merged, add as a normal node.
        if !(n1 in reduced_nodes)
            push!(reduced_nodes, n1)
            push!(supernodes, n1)
            generators_n1 = getGeneratorsByNode(n1)
            append!(producing_generators, generators_n1)
        end
    end
    
end

function solveS2(m, ramping)
    # Empty all dictionaries in case of multiple runs.
    empty!(subnodes)
    empty!(supernodes)
    empty!(reduced_nodes)
    empty!(reduced_lines)
    empty!(producing_generators)
    empty!(subgenerators)
    
    # Starting time for calculating setup time.
    t_start = time_ns()

    # Add objective, variables and constraints unaffected by symmetry reduction
    @variable(m, 0 ≤ vInvCost)
    @variable(m, 0 ≤ vOpeCost)
    @variable(m, 0 ≤ vGenInv[G]) 

    @objective(m, Min, vInvCost + vOpeCost)
    
    @constraint(m,
        vInvCost == sum(pInvCost[g] * pUnitCap[g] * vGenInv[g] for g in G)
    )

    # Reduce problem size
    reduceS2(m)

    # Add remaining variables and constraints
    @variable(m,           0 ≤ vGenProd[producing_generators, T])
    @variable(m, -pImpCap[l] ≤ vLineFlow[l in L, T] ≤ pExpCap[l])
    @variable(m,           0 ≤ vLossLoad[n in N, t in T] ≤ pDemand[(n, t)])

    @constraint(m,
        vOpeCost == pWeight * (
            sum(pVarCost[getGeneratorOrSub(g)] *  vGenProd[g, t] for g in producing_generators, t in T)
            + sum(pVOLL * vLossLoad[n, t] for n in N, t in T)
        )
    )   

    for n in supernodes
        if haskey(subnodes, n)
            newGenerators = getGeneratorsOfNewNode(n)
            n1 = subnodes[n][1]
            n2 = subnodes[n][2]

            @constraint(m, [g in newGenerators, t in T],
                vGenProd[g, t] <= sum(get(pGenAva, (sub..., t), 1.0) * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g])
            )

            @constraint(m, [t in T],
                sum(vGenProd[g, t] for g in newGenerators) + sum(vLineFlow[l, t] for l in L if (l[2] == n1 && l[1] != n2) || (l[2] == n2 && l[1] != n1)) - sum(vLineFlow[l, t] for l in L if (l[1] == n1 && l[2] != n2) || (l[1] == n2 && l[2] != n1)) + vLossLoad[n1, t] + vLossLoad[n2, t] == pDemand[(n1, t)] + pDemand[(n2, t)]
            )

            pairs = []
            for g in newGenerators
                if length(subgenerators[g]) == 2
                    push!(pairs, g)
                end
            end
            power = collect(powerset(pairs))

            for p in power
                @constraint(m, [t in T],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n1)) + sum(vGenProd[g, t] for g in p) + vLossLoad[n1, t] <= (pDemand[(n1, t)] + sum(vLineFlow[l, t] for l in L if (l[1] == n1); init=0) - sum(vLineFlow[l, t] for l in L if (l[2] == n1); init=0) + sum(sum(get(pGenAva, (sub..., t), 1.0) * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n2) for g in p))
                )

                @constraint(m, [t in T],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n2)) + sum(vGenProd[g, t] for g in p) + vLossLoad[n2, t] <= (pDemand[(n2, t)] + sum(vLineFlow[l, t] for l in L if (l[1] == n2); init=0) - sum(vLineFlow[l, t] for l in L if (l[2] == n2); init=0) + sum(sum(get(pGenAva, (sub..., t), 1.0) * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n1) for g in p))
                )
            end
            

            # Ramping constraints, not used in thesis, but could be useful for future reference.
            if ramping == "true"
                # eRampingUp
                @constraint(m, [g in newGenerators, t in T[2:length(T)]],
                    vGenProd[g, t] - vGenProd[g, t-1] ≤ sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g])
                )
                # eRampingDown
                @constraint(m, [g in newGenerators, t in T[2:length(T)]],
                    sum(-pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g]) <= vGenProd[g, t] - vGenProd[g, t-1]
                )

                @constraint(m, [t in T[1:length(T) - 1]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n1 || length(subgenerators[g]) == 2)) + vLossLoad[n, t] <= (pDemand[(n1, t + 1)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t + 1] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t + 1] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n1) for g in newGenerators)
                    + pDemand[(n2, t)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    )
                )

                @constraint(m, [t in T[1:length(T) - 1]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n2 || length(subgenerators[g]) == 2)) + vLossLoad[n, t] <= (pDemand[(n2, t + 1)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t + 1] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t + 1] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n2) for g in newGenerators)
                    + pDemand[(n1, t)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    )
                )

                @constraint(m, [t in T[2:length(T)]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n1 || length(subgenerators[g]) == 2)) + vLossLoad[n, t] <= (pDemand[(n1, t - 1)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t - 1] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t - 1] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n1) for g in newGenerators)
                    + pDemand[(n2, t)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    )
                )

                @constraint(m, [t in T[2:length(T)]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n2 || length(subgenerators[g]) == 2)) + vLossLoad[n, t] <= (pDemand[(n2, t - 1)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t - 1] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t - 1] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n2) for g in newGenerators)
                    + pDemand[(n1, t)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    )
                )

                @constraint(m, [t in T[1:length(T) - 1]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n1)) + vLossLoad[n, t] <= (pDemand[(n1, t + 1)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t + 1] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t + 1] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n1) for g in newGenerators)
                    )
                )

                @constraint(m, [t in T[1:length(T) - 1]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n2)) + vLossLoad[n, t] <= (pDemand[(n2, t + 1)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t + 1] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t + 1] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n2) for g in newGenerators)
                    )
                )

                @constraint(m, [t in T[2:length(T)]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n1)) + vLossLoad[n, t] <= (pDemand[(n1, t - 1)] + getCapFromTo(n1, n2)
                    + sum(vLineFlow[l, t - 1] for l in L if (l[1] == n1 && l[2] != n2); init=0)
                    - sum(vLineFlow[l, t - 1] for l in L if (l[2] == n1 && l[1] != n2); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n1) for g in newGenerators)
                    )
                )

                @constraint(m, [t in T[2:length(T)]],
                    sum(vGenProd[g, t] for g in newGenerators if (length(subgenerators[g]) == 1 && subgenerators[g][1][1] == n2)) + vLossLoad[n, t] <= (pDemand[(n2, t - 1)] + getCapFromTo(n2, n1)
                    + sum(vLineFlow[l, t - 1] for l in L if (l[1] == n2 && l[2] != n1); init=0)
                    - sum(vLineFlow[l, t - 1] for l in L if (l[2] == n2 && l[1] != n1); init=0)
                    + sum(sum(pRamping * pUnitCap[sub] * vGenInv[sub] for sub in subgenerators[g] if sub[1] == n2) for g in newGenerators)
                    )
                )

            end

        else
            generators_n = getGeneratorsByNode(n)
            @constraint(m, [t in T], (sum(vGenProd[g, t] for g in generators_n)
                + sum(vLineFlow[l, t] for l in L if l[2] == n; init=0.0)
                - sum(vLineFlow[l, t] for l in L if l[1] == n; init=0.0)
                + vLossLoad[n, t]
                ==
                pDemand[(n, t)])
            )

            @constraint(m, [g in generators_n, t in T], (vGenProd[g, t] <=
                    get(pGenAva, (g..., t), 1.0) * pUnitCap[g] * vGenInv[g])
            )

            if ramping == "true"
                # eRampingUp
                @constraint(m, [g in generators_n, t in T[2:length(T)]],
                    vGenProd[g, t] - vGenProd[g, t-1] ≤ pRamping * pUnitCap[g] * vGenInv[g]
                )
                # eRampingDown
                @constraint(m, [g in generators_n, t in T[2:length(T)]],
                    -pRamping * pUnitCap[g] * vGenInv[g] <= vGenProd[g, t] - vGenProd[g, t - 1]
                )
            end
        end
    end
    setup_time = (time_ns() - t_start) * 10^(-9)

    # Solve problem.
    optimize!(m)

    # Restore solution to original problem and determine time required to do so.
    t_start = time_ns()
    res = restoreS2(m)
    restore_time = (time_ns() - t_start) * 10^(-9)

    return res, setup_time, restore_time
end

function restoreS2(m)
    # Transform solution to reduced problem to solution to original problem.
    
    # Set resulting costs.
    invCost = JuMP.value(m[:vInvCost])
    opeCost = JuMP.value(m[:vOpeCost])
    
    # Create all resulting dictionaries.
    genInv = Dict()
    genProd = Dict()
    lossLoad = Dict()
    lineFlow = Dict()
    
    # Loop over all nodes and time steps to set missed demand.
    for n in N
        for t in T
            lossLoad[(n, t)] = JuMP.value(m[:vLossLoad][n,t])
        end
    end

    # Loop over all lines to set flows.
    for l in L
        for t in T
            lineFlow[(l, t)] = JuMP.value(m[:vLineFlow][l,t])
        end
    end
    
    # Loop over all generators to calculate production values.
    for g in producing_generators
        # If g is a merged plant, calculate values, else use the values from the solved model.
        if haskey(subgenerators, g)
            # If subgenerators of g has length 1, it is in a merged node but not merged itself, so we can use the values from the solver.
            if length(subgenerators[g]) == 1
                sub = subgenerators[g][1]
                genInv[sub] = JuMP.value(m[:vGenInv][sub])
                for t in T
                    genProd[(sub,t)] = JuMP.value(m[:vGenProd][g, t])
                end
            else
                # Determine subplants.
                g1 = subgenerators[g][1]
                g2 = subgenerators[g][2]
                genInv[g1] = JuMP.value(m[:vGenInv][g1])
                genInv[g2] = JuMP.value(m[:vGenInv][g2])
                new_gen = getGeneratorsOfNewNode(g[1])
                # For each time step, greedily calculate production of both subplants.
                for t in T
                    genProd[(g1, t)] = (pDemand[(g1[1], t)] - lossLoad[(g1[1], t)] + sum(JuMP.value(m[:vLineFlow][l, t]) for l in L if (l[1] == g1[1]); init=0) -
                    sum(JuMP.value(m[:vLineFlow][l, t]) for l in L if (l[2] == g1[1]); init=0) - sum(JuMP.value(m[:vGenProd][gn, t]) for gn in new_gen if (length(subgenerators[gn]) == 1 && subgenerators[gn][1] == g1); init=0))
                    genProd[(g2, t)] = JuMP.value(m[:vGenProd][g, t]) - genProd[(g1,t)]
                end
            end
        else
            genInv[g] = JuMP.value(m[:vGenInv][g])
            for t in T
                genProd[(g,t)] = JuMP.value(m[:vGenProd][g, t])
            end
        end
    end

    return Solution(invCost, opeCost, genInv, genProd, lossLoad, lineFlow)
end