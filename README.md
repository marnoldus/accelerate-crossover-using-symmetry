# Exploiting Symmetry in the Generation Expansion Planning Problem to Accelate Crossover

This repository contains the input data, code and results for my MSc Thesis. The full thesis can be found in the [TU Delft repository](https://repository.tudelft.nl/islandora/object/uuid%3Ae698df15-05ac-4b74-84da-bbe30c29adba?collection=education).

## Usage

To run this project, follow the following steps:
- Download the [Julia](https://julialang.org/) programming language.
- Configure config.toml using the correct input files, output files and parameters.
- Run gep-main.jl.

## Input data

The data used for my thesis is a simplified version of a case study built from public data sources on the European energy market from ENTSO-E [[1]](#1). The input folder contains three scenarios: the baseline of my thesis, a scenario containing symmetry between power plants in the same node and a scenario containing symmetry between power plants of connected nodes.

## Output

The output folder contains the output logs corresponding to the results in my thesis. Each file is named by the figure of my thesis it corresponds to.

## License

This content is released under the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).

## References

<a id="1">[1]</a> 
“Tyndp 2022 scenario report – introduction and executive summary,” TYNDP 2022, https://2022.entsos-tyndp-scenarios.eu/wp-content/uploads/2022/04/TYNDP2022_Joint_Scenario_Full-Report-April-2022.pdf.
