using DataFrames
using JuMP

"""
    dataframe_to_dict(
        df::AbstractDataFrame,
        keys::Union{Symbol, Vector{Symbol}},
        value::Symbol
    ) -> Dict

Convert the dataframe `df` to a dictionary using columns `keys` as keys and
`value` as values. `keys` can contain more than one column symbol, in which case
a tuple key is constructed.
"""
function dataframe_to_dict(
    df::AbstractDataFrame,
    keys::Union{Symbol, Vector{Symbol}},
    value::Symbol
)::Dict
    return if typeof(keys) <: AbstractVector
        Dict(Tuple.(eachrow(df[!, keys])) .=> Vector(df[!, value]))
    else
        Dict(Vector(df[!, keys]) .=> Vector(df[!, value]))
    end
end


"""
Returns a `DataFrame` with the values of the variables from the JuMP container
`container`. The column names of the `DataFrame` can be specified for the
indexing columns in `dim_names`, and the name of the data value column by a
Symbol `value_col` e.g. `:Value`.
"""
function jump_container_to_df(container::JuMP.Containers.DenseAxisArray;
    dim_names=Vector{Symbol}(),
    value_col::Symbol=:Value)

    if isempty(container)
        return DataFrame()
    end

    if length(dim_names) == 0
        dim_names = [Symbol("dim$i") for i in 1:length(container.axes)]
    end

    if length(dim_names) != length(container.axes)
        throw(ArgumentError("Length of given name list does not fit the number of variable dimensions"))
    end

    dim_names = [dim_names..., value_col]
    df = DataFrame(Containers.rowtable(container))

    for (a, b) in zip(dim_names, names(df))
        if typeof(a) <: Tuple
            select!(df, Not(b), b => [a...]) # expand tuple columns
        else
            select!(df, Not(b), b => a) # rename other columns
        end
    end

    # move the value column to the end
    select!(df, Not(value_col), value_col)
    
    return df
end
