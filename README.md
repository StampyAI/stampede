# Stampede

Stampede is in a very early state and may drastically change. It doesn't have releases yet but we try to keep changes in the `dev` branch until it runs and passes tests.

Stampede is a chat bot backend meant to serve *multiple servers and services simultaneously*, choosing its response between multiple competing plugins to give the most relevant response. It focuses on supporting a conversational style, and can use LLMs, but will prefer to answer using human-made code. (Wikipedia, Q&A databases, etc)

It is a sequel to the [Stampy](https://github.com/StampyAI/stampy) Discord bot.

## Use

Configurations are written in YAML and left in `./Sites/`. In different environments (such as `test` and `dev`) it will read configs from `./Sites_{environment-name}`. Check the service documentation for what options your service has available.

- `./lib/services` defines services where chat requests are incoming.
- `./lib/plugins` defines plugins which suggest potential responses, along with a confidence estimate for how relevant the response would be. Plugins which use resources or take time will offer a *callback* instead, which will only be called if no other plugins have higher confidence.
