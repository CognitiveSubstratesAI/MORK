using Documenter
using MORK

DocMeta.setdocmeta!(MORK, :DocTestSetup, :(using MORK); recursive=true)

makedocs(;
    modules=[MORK],
    authors="CognitiveSubstrates AI",
    repo=Remotes.GitHub("CognitiveSubstratesAI", "MORK"),
    sitename="MORK.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://cognitivesubstratesai.github.io/MORK/stable/",
        edit_link="main",
        assets=String[]
    ),
    pages=[
        "Home" => "index.md",
        "Guide" => [
            "Expressions" => "guide/expressions.md",
            "Zipper Queries" => "guide/zipper_queries.md",
            "Space Rules" => "guide/space_rules.md",
            "Sources and Sinks" => "guide/sinks.md",
            "Server" => "guide/server.md"
        ],
        "Examples" => [
            "Fly connectome (FAFB v783)" => "examples/fly_connectome.md",
        ],
        "API Reference" => "api/README.md"
    ],
    warnonly=true
)

deploydocs(; repo="github.com/CognitiveSubstratesAI/MORK", devbranch="main")
