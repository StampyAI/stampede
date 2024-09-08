# Stampede

Stampede is in a very early state and may drastically change. It doesn't have releases yet but we try to keep changes in the `dev` branch until it runs and passes tests.

Stampede is a chat bot backend meant to serve *multiple servers and services simultaneously*, choosing its response between multiple competing plugins to give the most relevant response. It focuses on supporting a conversational style, and can use LLMs, but will prefer to answer using human-made code. (Wikipedia, Q&A databases, etc)

It is a sequel to the [Stampy](https://github.com/StampyAI/stampy) Discord bot.

## Use

[Download the Nix package manager](https://github.com/DeterminateSystems/nix-installer). This handles the development environment for Stampede. It runs on Linux, Mac, Windows, and Docker. It won't disrupt your system setup -- though once you start using it, it may be hard to stop. :smile:

Once Nix is ready, just cd to the dev directory and run `nix develop .#` to load the dev environment, then `mix deps.get` to get the dependencies. Some commands:
- `iex -S mix` to run Stampede in the `dev` environment, also providing the famous Elixir interactive shell.
- `mix test` to run tests
- `mix dialyzer` to typecheck
- `mix credo` to simulate a senior engineer nitpicking

Configurations for servers are written in YAML and left in `./Sites/`. In different environments (such as `test` and `dev`) it will read configs from `./Sites_{environment-name}`. Check the service documentation for what options your service has available.

  - `./lib/services` defines services where chat requests are incoming. They follow the standard set in `./lib/service.ex`
- `./lib/plugins` defines plugins which suggest potential responses, along with a confidence estimate for how relevant the response would be. Plugins which use resources or take time will offer a *callback* instead, which will only be called if no other plugins have higher confidence. They follow the standard set in `./lib/plugin.ex`

### Updating `.dialyzer_ignore.exs`

Often when changing code, you will end up with superfluous Dialyzer warnings. You can suppress them by updating the Dialyzer ignore file. To start:

```bash
rm ./.dialyzer_ignore.exs
mix dialyzer --format ignore_file_strict &> .dialyzer_ignore.exs.incoming
```

Remove all but the Elixir tuples, which will look like this:

```elixir
{"lib/stampede.ex", "Function server_id/0 has no local return."},
```

Put a `[` at the start of the file and a `]` at the end, so they become one list of tuples. Now you can rename the file to its true name and format it:

```bash
mv ./.dialyzer_ignore.exs{.incoming,}
mix format ./.dialyzer_ignore.exs
```

Now Dialyzer should not raise any more warnings.
