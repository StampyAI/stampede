# Stampede

Stampede is a chat bot backend meant to serve multiple servers and services simultaneously, choosing its response between multiple competing plugins to choose the most relevant response. It focuses on supporting a conversational style, and can use LLMs, but will prefer to answer questions from databases if possible.

Stampede is in a very early state and may drastically change. It is a sequel to the [Stampy](https://github.com/StampyAI/stampy) Discord bot.

## Use

Configurations are written in YAML and left in `./Sites/`. In different environments (such as `test` and `dev`) it will use configs from `./Sites_{environment-name}`.

- `./lib/services` defines services where chat requests are incoming.
- `./lib/plugin` defines plugins which suggest potential responses, along with a confidence estimate for how relevant the response would be. Plugins which use resources or take time will offer a *callback* instead, which will only be called if no other plugins have higher confidence.
