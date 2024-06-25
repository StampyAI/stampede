%{
  configs: [
    %{
      name: "default",
      checks: %{
        disabled: [
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []}
        ]
      }
    }
  ]
}
