using UnicodePlots
using Statistics
using DataFrames
using TOML

function print_message(text::String; level::Int=3)
    if level == 1
        println()
        printstyled(text, color=Base.info_color(), bold=true)
        println()
    elseif level == 2
        println()
        printstyled(text, bold=true)
        println()
    elseif level == 3
        println(text)
    else
        println(text)
    end
end

function terminal_barplot(
    df::DataFrame,
    text_col::Symbol,
    heights_col::Symbol,
    statistic::Function,
    title::AbstractString,
    visualization_data::Dict{Symbol, Any}
)
    color_dict = visualization_data[:colors]
    alias_dict = visualization_data[:alias]
    label_length = maximum(length.(values(alias_dict)))

    d = combine(groupby(df, text_col), heights_col => statistic, renamecols=false)
    transform!(d, text_col => ByRow(x -> Tuple(get(color_dict, Symbol(x), color_dict[:default]))) => :color)
    transform!(d, text_col => ByRow(x -> get(alias_dict, Symbol(x), x)) => text_col)
    margin = label_length - maximum(length.(string.(d[!, text_col])))
    
    sorting = get(visualization_data[:sorting], text_col, nothing)
    if sorting ≢ nothing
        order = [get(alias_dict, Symbol(x), x) for x in sorting]
        sort!(d, by = x ->
            begin
                i = findfirst(==(x), order)
                i ≡ nothing ? 0 : i
            end
        )
    else
        sort!(d)
    end
    println(barplot(d[!, text_col], d[!, heights_col], color = d.color, title=title, margin=margin))
end

function print_input_statistics(inputs, visualization_data)

    terminal_barplot(inputs[:demand_data], :Country, :Demand_MW, mean,
        "Demand [MW]", visualization_data)
    
    terminal_barplot(inputs[:generation_data], :Technology, :InvCost_kEUR_MW_year, mean,
        "Investment Cost [k€/MW/year]", visualization_data)
    terminal_barplot(inputs[:generation_data], :Technology, :VarCost_kEUR_per_MWh, mean,
        "Variable Production Cost [k€/MWh]", visualization_data)
    terminal_barplot(inputs[:generation_data], :Technology, :UnitCap_MW, mean,
        "Capacity [MWh/unit]", visualization_data)
    
    terminal_barplot(inputs[:generation_availability_data], :Country, :Availability_pu, mean,
        "Renewable energy availability [--/unit]", visualization_data)
    terminal_barplot(inputs[:generation_availability_data], :Technology, :Availability_pu, mean,
        "Renewable energy availability [--/unit]", visualization_data)
    
    terminal_barplot(inputs[:generation_availability_data], :Technology, :Availability_pu, mean,
        "Renewable energy availability [--/unit]", visualization_data)
    
    df = vcat(
        select(inputs[:transmission_lines_data], :CountryA => :Country, :CountryB => :To, :ExpCap_MW => :Cap),
        select(inputs[:transmission_lines_data], :CountryB => :Country, :CountryA => :To, :ImpCap_MW => :Cap)
    
    )
    
    for d in groupby(df, :Country)
        name = first(d.Country)
        name_alias = string(get(visualization_data[:alias], Symbol(name), name))
        terminal_barplot(DataFrame(d), :To, :Cap, mean,
            "Transmission Line Capacities from " * name_alias * " [MW]",
            visualization_data
        )
    end
end

function print_output_statistics(outputs, visualization_data)
    if haskey(outputs, :λ)
        terminal_barplot(outputs[:λ], :Country, :Value, mean, "Mean dual value [EUR/MWh]", visualization_data)
        #terminal_barplot(outputs[:λ], :Time,    :Value, mean, "Mean dual value [EUR/MWh]", visualization_data)
    end

    terminal_barplot(outputs[:vGenInv], :Country, :Value, sum, "New capacity [MW]", visualization_data)
    terminal_barplot(outputs[:vGenInv], :Technology, :Value, sum, "New capacity [MW]", visualization_data)
        
    terminal_barplot(outputs[:vGenProd], :Country, :Value, sum, "Generation [MWh]", visualization_data)
    terminal_barplot(outputs[:vGenProd], :Technology, :Value, sum, "Generation [MWh]", visualization_data)
    #terminal_barplot(vGenProd_df, :Time, :Value, sum, "Generation [MWh]", visualization_data)
end
