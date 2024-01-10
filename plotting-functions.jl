using JuMP, HiGHS, DataFrames, Chain
using Plots
# using Interact
using StatsPlots
using Statistics

function plot_avg_price_per_country(df_::DataFrame)

    df =(@chain df_ begin
            groupby(:Country)
            combine(:Value => mean => :Mean_val)
            sort(:Mean_val, rev=true)
        end)
    
    p = bar(df.Country,
             df.Mean_val*1e3/pWeight,
             xlabel="Country [-]", 
             ylabel="Average λ [EUR/MWh]",
             legend=false,
             lw=0
            )

    return p
end

function plot_avg_price_per_hour(df_::DataFrame)

    df =(@chain df_ begin
            groupby(:Time)
            combine(:Value => mean  => :Mean_val)
        end)
    
    p = bar(df.Time,
             df.Mean_val*1e3/pWeight,
             xlabel="Timesteps [-]", 
             ylabel="Average λ [EUR/MWh]",
             legend=false,
             lw=0
             )

    return p
end

function plot_outputs(outputs, inputs)
    # create arrays for plotting
    gvec   = combine(groupby(outputs[:vGenProd], [:Technology, :Time]), :Value => sum => :Value)
    gvec.Value = gvec.Value
    gvec = unstack(gvec, :Technology, :Value)
    select!(gvec, Not(:Time))

    capvec = outputs[:vGenInv]
    capvec.Value = capvec.Value
    capvec = combine(groupby(capvec, :Technology), :Value => sum => :Value)
    
    # average electricity price price
    if haskey(outputs, :λ)
        p1a = outputs[:λ] |> plot_avg_price_per_country
        p1b = outputs[:λ] |> plot_avg_price_per_hour
    end

    combine(groupby(inputs[:demand_data], :Time), :Demand_MW => sum)
    
    # dispatch
    p2 = groupedbar(Matrix(gvec) / 1e3,
        legend = false,
        bar_position = :stack,
        xlabel="Timesteps [-]",
        ylabel="Generation [GWh]",
        lw = 0
    );

    # capacity
    p3 = bar(capvec.Technology, capvec.Value / 1e3, 
        label=false,
        xlabel="Technology [-]",
        ylabel="New capacity [GW]",
        lw=0
    );

    # Combine
    if haskey(outputs, :λ) 
        plot(p1a, p1b, p2, p3, layout = (2, 2))
    else
        plot(p2, p3, layout = (2, 1))
    end
    plot!(size=(800,800))
end
