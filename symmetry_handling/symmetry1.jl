subgenerators = Dict()
supergenerators = []
reduced_generators = []

function gaEquals(ga, g1, g2)
    # Check if the generation availability profile of two plants is exactly equal.
    for t in T
        if get(ga, (g1,t), 1.0) != get(ga, (g2,t), 1.0)
            return false
        end
    end
    return true
end

function reduceS1(generators, ucap, ic, pc, ga)
    # Restore Dicts and lists (necessary for multiple runs after each other)
    empty!(subgenerators)
    empty!(supergenerators)
    empty!(reduced_generators)
    # Loop over all generators
    for g1 in generators
        # If g1 already added to another generator, continue.
        if g1 in reduced_generators
            continue
        end
        # Else, g1 is added to the new set of generators
        push!(supergenerators, g1)
        sub = []
        # Check if any of the other generators is symmetric to g1.
        for g2 in generators
            # If g2 = g1, g2 already reduced by another generator, or g2 already its own generator, or in a different node, continue.
            if g1 == g2 || g2 in reduced_generators || g2 in supergenerators || g1[1] != g2[1]
                continue
            end
            # If all costs, capacities, generation availabilities are the same, merge g2 into g1.
            if ucap[g1] == ucap[g2] && ic[g1] == ic[g2] && pc[g1] == pc[g2] && gaEquals(ga, g1, g2)
                push!(reduced_generators, g2)
                push!(sub, g2)
            end
        end
        # Store subgenerators of g1.
        subgenerators[g1] = sub
    end
    return supergenerators
end

function restoreS1(m)
    # Create dictionaries for results.
    vGenInv = Dict()
    vGenProd = Dict()
    # Loop over all plants in the reduced problem.
    for g_new in supergenerators
        # Calculate and set investment per node.
        sub = subgenerators[g_new]
        inv_per_node = JuMP.value(m[:vGenInv][g_new]) / (length(sub) + 1)
        vGenInv[g_new] = inv_per_node
        for g in sub
            vGenInv[g] = inv_per_node
        end
        # Calculate and set production per node per time step.
        for t in T
            prod_per_node = JuMP.value(m[:vGenProd][g_new, t]) / (length(sub) + 1)
            vGenProd[g_new,t] = prod_per_node
            for g in sub
                vGenProd[g,t] = prod_per_node
            end
        end
    end   
    return vGenInv, vGenProd
end