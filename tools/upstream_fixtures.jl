# Auto-generated upstream fixtures — do not edit manually
# Regenerate with: record_fixtures() in tools/diff_upstream.jl
const UPSTREAM_FIXTURES = Dict{String, String}(
    "lookup" => "(Something (very specific))\nMATCHED\n",
    "positive" => "(Something (very specific))\nMATCHED\n",
    "positive_equal" => "(Something (very specific) (very specific))\nMATCHED\n",
    "negative" => "(Something \$)\nMATCHED\n",
    "negative_equal" => "(Something \$ _1)\nMATCHED\n",
    "bipolar" => "(Something (\$ specific))\nMATCHED\n",
    "top_level" => "bar\nfoo\n",
    "two_positive_equal" => "(Else (bar baz) (bar baz))\n(Something (foo bar) (foo bar))\nMATCHED\n",
    "two_positive_equal_crossed" => "(Else (foo bar) (bar baz))\n(Something (foo bar) (bar baz))\nMATCHED\n",
    "two_bipolar_equal_crossed" => "(Else (\$ bar) (_1 bar))\n(MATCHED (foo \$) (foo _1))\n(MATCHED (foo bar) (foo bar))\n(Something (foo \$) (foo _1))\n",
    "variable_priority" => "(A Z)\n(B Z)\n",
    "variables_in_priority" => "(A Z)\n(B Z)\n",
    "func_type_unification" => "(a (: \$ A))\n(b (: f (-> A)))\n(c OK)\n",
    "issue_43" => "(data (0 1))\n(l \$ _1)\n(((. \$) _1) lp 0 1)\n"
)
