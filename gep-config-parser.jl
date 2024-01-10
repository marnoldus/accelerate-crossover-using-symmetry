using TOML
using CSV
using DataFrames

# All of the literals are defined here. This way, if the layout of the config
# file changes, you can change the value once, instead of going through the 
# whole script. If you use any literal, please define it here.

const AUTO                 = "auto"
const FROM                 = "from"
const TO                   = "to"

const OPTIMIZER_TABLE      = "optimizer"
const INPUTS_TABLE         = "inputs"
const SCALARS_TABLE        = "scalars"
const DATA_TABLE           = "data"
const SETS_TABLE           = "sets"
const OUTPUTS_TABLE        = String(:outputs)

const SOLVER_KEY           = String(:solver)
const DIR_KEY              = String(:dir)
const FILE_KEY             = String(:file)

const DEMAND_KEY           = String(:demand)
const GENERATION_KEY       = String(:generation)
const GENERATION_AVAIL_KEY = String(:generation_availability)
const TRANSMISSION_KEY     = String(:transmission_lines)
const TIMES_KEY            = String(:times)
const NODES_KEY            = String(:nodes)
const GENERATORS_KEY       = String(:transmission_lines)
const LINES_KEY            = String(:generators)

const SOLVER_UNSUPPORTED_MESSAGE =
    "Only Gurobi and HIGHS solvers are supported at the moment."
const WRONG_SET_MESSAGE =
    "Wrong set description. Either provide a list, or use `auto` to infer it."

# Helper functions

"""
    prepend_dir(dir::AbstractString) -> Function

Return a new function `path -> joinpath(dir, path)` that prepends any path (or 
    just a file name) `path` with the directory `dir`.
"""
prepend_dir(dir::AbstractString)::Function = path -> joinpath(dir, path)

"""
    read_config(file_name::AbstractString) -> Dict{String, Any}

Parse the contents of the config file `file_name` into a dictionary. The file
must be in TOML format.
"""
read_config(file_name::AbstractString)::Dict{String, Any} =
    TOML.parsefile(file_name)

"""
    initialize_model(optimizer,  attributes) -> JuMP.Model

Initialize a new JuMP model with given optimizer and its attributes.
`attributes` must be a dictionary with attribute names as keys.
"""
function initialize_model(
    optimizer,  attributes
)::JuMP.Model
    # Group the constructor with these attributes for initialization in the
    # model.
    optimizer_constructor_with_attributes = optimizer_with_attributes(
        optimizer,
        attributes...
    )

    # Initialize the model given the optimizer and attributes and return it.
    return Model(optimizer_constructor_with_attributes)
end

"""
    convert_keys_to_symbols(dict::AbstractDict{String, Any}) ->
        Dict{Symbol, Any}

Create a new dictionary that is identical to `dict`, except all of the keys 
are converted from strings to
[symbols](https://docs.julialang.org/en/v1/manual/metaprogramming/#Symbols).
Symbols are [interned](https://en.wikipedia.org/wiki/String_interning) and are
faster to work with when they serve as unique identifiers.
"""
function convert_keys_to_symbols(
    dict::AbstractDict{String, Any};
    recursive::Bool=true
)::Dict{Symbol, Any}
    return Dict(Symbol(k) =>
        if recursive && typeof(v) <: Dict
            convert_keys_to_symbols(v)
        else
            v
        end
        for (k, v) in dict
    )
end

"""
    read_scalars(scalars_config::AbstractDict{String, Any},
        inputs_dir::AbstractString) -> Dict{Symbol, Any}

Read the scalar data from a file specified in `scalars_config` located in the
directory `inputs_dir`. The keys are converted to
[symbols](https://docs.julialang.org/en/v1/manual/metaprogramming/#Symbols).
"""
function read_scalars(
    scalars_config::AbstractDict{String, Any},
    inputs_dir::AbstractString
)::Dict{Symbol, Any}
    scalars = scalars_config[FILE_KEY] |>
        prepend_dir(inputs_dir) |>
        TOML.parsefile
    return convert_keys_to_symbols(scalars)
end

"""
    read_scalars(data_config::AbstractDict{String, Any},
        inputs_dir::AbstractString) -> Dict{Symbol, DataFrame}

Read the data from .csv files specified in `data_config` located in the
directory `inputs_dir`. The data is presented as a dictionary with keys
`:demand_data`, `:generation_data`, `:generation_availability_data`, and
`:transmission_lines_data`. Each value is a `DataFrame` read from the
corresponding .csv file.
"""
function read_data(
    data_config::AbstractDict{String, Any},
    inputs_dir::AbstractString
)::Dict{Symbol, DataFrame}

    read_data_frame = key ->
        data_config[key] |>
        prepend_dir(inputs_dir) |>
        CSV.File |>
        DataFrame

    return Dict(
        :demand_data                  => read_data_frame(DEMAND_KEY),
        :generation_data              => read_data_frame(GENERATION_KEY),
        :generation_availability_data => read_data_frame(GENERATION_AVAIL_KEY),
        :transmission_lines_data      => read_data_frame(TRANSMISSION_KEY),
    )
end

"""
    read_sets(sets_config::AbstractDict{String, Any}) -> Dict{Symbol, Any}

Read the sets from `sets_config`. The keys are converted to
[symbols](https://docs.julialang.org/en/v1/manual/metaprogramming/#Symbols).
The sets either list times, nodes, generators, and transmission lines to include
in the model, or are set to `\"auto\"`, in which case they are later inferred
from the data read from the .csv files.
"""
function read_sets(sets_config::AbstractDict{String, Any})::Dict{Symbol, Any}
    return convert_keys_to_symbols(sets_config)
end

"""
    resolve_sets!(dict::AbstractDict{Symbol, Any})

Check that the sets are set to correct values. If the sets are set to
`\"auto\"`, infers them from the data frames `dict[:demand_data]`,
`dict[:generation_data]`, `dict[:generation_availability_data]`, and 
`dict[:transmission_lines_data]`.
"""
function resolve_sets!(dict::AbstractDict{Symbol, Any})
    resolve_times!(dict)
    resolve_nodes!(dict)
    resolve_generators!(dict)
    resolve_transmission_lines!(dict)
end

"""
    resolve_nodes!(dict::AbstractDict{Symbol, Any})

Check that the node set is defined correctly. If it is set to
`\"auto\"`, infers the nodes from the data frames `dict[:demand_data]`,
`dict[:generation_data]`, `dict[:generation_availability_data]`, and 
`dict[:transmission_lines_data]`.
"""
function resolve_times!(dict::AbstractDict{Symbol, Any})
    times = dict[:times]
    if typeof(times) <: AbstractString
        if times != AUTO
            throw(DomainError(times, WRONG_SET_MESSAGE))
        end
        # Find all unique values of time steps in the data files
        from = min(
            minimum(dict[:demand_data][!,:Time]),
            minimum(dict[:generation_availability_data][!,:Time])
        )
        to = max(
            maximum(dict[:demand_data][!,:Time]),
            maximum(dict[:generation_availability_data][!,:Time]),
        )
    elseif typeof(times) <: Dict
        from = times[:from]
        to = times[:to]
    elseif !(typeof(times) <: Integer)
        throw(DomainError(times, WRONG_SET_MESSAGE))
    end
    dict[:times] = from:to
end

"""
    resolve_nodes!(dict::AbstractDict{Symbol, Any})

Check that the node set is defined correctly. If it is set to
`\"auto\"`, infers the nodes from the data frames `dict[:demand_data]`,
`dict[:generation_data]`, `dict[:generation_availability_data]`, and 
`dict[:transmission_lines_data]`.
"""
function resolve_nodes!(dict::AbstractDict{Symbol, Any})
    nodes = dict[:nodes]
    if typeof(nodes) <: AbstractString
        if nodes != AUTO
            throw(DomainError(nodes, WRONG_SET_MESSAGE))
        end
        # Find all unique values of nodes in the data files
        nodes = Set(dict[:demand_data][!,:Country])
        union!(nodes, dict[:generation_data][!,:Country])
        union!(nodes, dict[:generation_availability_data][!,:Country])
        union!(nodes, dict[:transmission_lines_data][!,:CountryA])
        union!(nodes, dict[:transmission_lines_data][!,:CountryB])
    elseif !(typeof(nodes) <: Vector{String})
        throw(DomainError(nodes, WRONG_SET_MESSAGE))
    end
    dict[:nodes] = String.(nodes)
end

"""
    resolve_generators!(dict::AbstractDict{Symbol, Any})

Check that the generators set is defined correctly. If it is set to
`\"auto\"`, infers the node-technology pairs from the data frames
`dict[:generation_data]` and `dict[:generation_availability_data]`.
"""
function resolve_generators!(dict::AbstractDict{Symbol, Any})
    generators = dict[:generators]
    if typeof(generators) <: AbstractString
        if generators != AUTO
            throw(DomainError(generators, WRONG_SET_MESSAGE))
        end
        # Find all unique values of node-technology pairs in the data files
        generators = dict[:generation_data][!,[:Country, :Technology]] |>
            eachrow |>
            x -> Tuple.(x) |>
            Set
        generators_availability = dict[:generation_availability_data][!,[:Country, :Technology]] |>
            eachrow |>
            x -> Tuple.(x) |>
            Set  
        union!(generators, generators_availability)
    elseif !(typeof(generators) <: Vector{Vector{String}})
        throw(DomainError(generators, WRONG_SET_MESSAGE))
    end
    dict[:generators] = Tuple{String, String}.(generators)
end

"""
    resolve_transmission_lines!(dict::AbstractDict{Symbol, Any})

Check that the transmission lines set is defined correctly. If it is set to
`\"auto\"`, infers the transmission lines from the data frame
`dict[:transmission_lines_data]`.
"""
function resolve_transmission_lines!(dict::AbstractDict{Symbol, Any})
    lines = dict[:transmission_lines]
    if typeof(lines) <: AbstractString
        if lines != AUTO
            throw(DomainError(lines, WRONG_SET_MESSAGE))
        end
        # Find all unique transmission lines in the data files
        lines = dict[:transmission_lines_data][!,[:CountryA, :CountryB]] |>
            eachrow |>
            x -> Tuple.(x) |>
            Set
    elseif !(typeof(lines) <: Vector{Vector{String}})
        throw(DomainError(lines, WRONG_SET_MESSAGE))
    end
    dict[:transmission_lines] = Tuple{String, String}.(lines)
end

"""
    read_inputs(inputs_config::AbstractDict{String, Any}) -> Dict{Symbol, Any}

Read input data based on the config. The data includes scalars, data frames from
.csv files, and indexing sets of nodes, generators, and transmission lines for
the optimizer.
"""
function read_inputs(
    inputs_config::AbstractDict{String, Any}
)::Dict{Symbol, Any}
    # Determine the input directory
    inputs_dir = inputs_config[DIR_KEY] |> prepend_dir(@__DIR__)

    # Process the scalars
    scalars_config = inputs_config[SCALARS_TABLE]
    scalars = read_scalars(scalars_config, inputs_dir)

    # Process the data files
    data_config = inputs_config[DATA_TABLE]
    data = read_data(data_config, inputs_dir)

    # Process the sets
    sets_config = inputs_config[SETS_TABLE]
    sets = read_sets(sets_config)

    # Process parameters
    output_file = inputs_config["output_file"]
    output_log = inputs_config["output_log"]
    relaxed = inputs_config["relaxed"]
    ramping = inputs_config["ramping"]
    symmetry = inputs_config["symmetry"]

    # Combine the resuts, and resolve the set values if they are set to "auto".
    result = merge(scalars, data, sets, Dict(:output_file => output_file, :output_log => output_log, :ramping => ramping, :relaxed => relaxed, :symmetry => symmetry))
    resolve_sets!(result)
    return result
end


function read_experiment(
    experiment_config::AbstractDict{String, Any}
)::Dict{Symbol, Any}
    repeats = experiment_config["repeats"]
    configurations = experiment_config["configurations"]
    experiments = Array{Any}(undef, configurations)
    for i in eachindex(experiment_config["inputs"])
        inputs_config = experiment_config["inputs"][i]
        inputs = read_inputs(inputs_config)
        experiments[i] = inputs
    end
    result = Dict(:repeats => repeats, :experiments => experiments)
    return result
end

"""
    parse_config(file_name::AbstractString)::Dict{Symbol, Any}

Parses the config file `file_name` and returns the data as a dictionary
containing the following values:

:inputs  => input data dictionary with the sets, data frames, and scalars based
            on the `[inputs]` table in the config

:model   => initialized optimization model based on the `[optimizer]` table in
            the config

:outputs => output data based on the `[outputs]` table in the config
"""
function parse_config(file_name::AbstractString)::Dict{Symbol, Any}
    config = read_config(file_name)

    experiment_config = config["experiment"]
    experiment = read_experiment(experiment_config)
    # inputs_config = config[INPUTS_TABLE]
    # inputs = read_inputs(inputs_config)

    optimizer_config = convert_keys_to_symbols(
        config[OPTIMIZER_TABLE],
        recursive=false
    )

    outputs_config = convert_keys_to_symbols(config[OUTPUTS_TABLE])

    return Dict(
        :experiment  => experiment,
        :optimizer_config => optimizer_config,
        :outputs_config => outputs_config
    )
end


get_visualization_data(file_name::AbstractString) = file_name |>
    TOML.parsefile |>
    convert_keys_to_symbols
