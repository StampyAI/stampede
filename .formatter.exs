# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,bench}/**/*.{ex,exs}"],
  # don't add parens around assert_value arguments
  import_deps: [:assert_value],
  # use this line length when updating expected value
  # whatever you prefer, default is 98
  line_length: 98
]
