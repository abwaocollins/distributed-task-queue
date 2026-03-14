%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: [
        {Credo.Check.Design.AliasUsage},
        {Credo.Check.Design.DuplicatedCode},
        {Credo.Check.Readability.MaxLineLength, [max_length: 120]},
        {Credo.Check.Readability.ModuleDoc},
        {Credo.Check.Readability.FunctionNames},
        {Credo.Check.Refactor.CyclomaticComplexity}
      ]
    }
  ]
}
