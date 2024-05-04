alias Stampede, as: S
require Stampede.Msg

defmodule T do
  require Plugin

  def make_fake_modules(num) when is_integer(num) and num > 0 do
    Enum.reduce(0..num, MapSet.new(), fn i, acc ->
      name = Module.concat(Plugin, "fake_#{i}")

      contents =
        quote do
          use Plugin

          def query(cfg, msg) do
            Process.sleep(unquote(i))
            Plugin.Test.query(cfg, msg)
          end

          def respond(arg) do
            Process.sleep(unquote(i * 2))

            Plugin.Test.respond(arg)
            |> then(fn
              m when is_map(m) ->
                Map.put(m, :origin_plug, __MODULE__)

              other ->
                other
            end)
          end
        end

      Module.create(name, contents, Macro.Env.location(__ENV__))
      Code.ensure_loaded!(name)

      MapSet.put(acc, name)
    end)
  end

  def make_messages(num, for_every) do
    Stream.unfold(0, fn i ->
      {
        (Integer.mod(i, for_every) == 0 && :ping) || :unrelated,
        i + 1
      }
    end)
    |> Enum.take(num)
  end

  def stupid_get_top_response(cfg, msg) do
    if Plugin.is_bot_needed(cfg, msg) do
      for plug <- cfg.plugs do
        {
          plug,
          Plugin.get_response({plug, :query, [cfg, msg]}, cfg, msg)
          |> case do
            {:job_ok, {:respond, arg}} ->
              Plugin.get_response({plug, :respond, [arg]}, cfg, msg)

            other ->
              other
          end
        }
      end
      |> Plugin.resolve_responses()
      |> Map.fetch!(:r)
    else
      nil
    end
  end
end

inputs = %{
  "20 modules, 100 messages" => %{mods: T.make_fake_modules(20), msgs: T.make_messages(100, 3)}
}

{:ok, _} = Application.ensure_all_started(:stampede)

Benchee.run(
  %{
    "Current plugin processing code" => {
      fn {cfg, tasks} ->
        {
          length(tasks),
          tasks
          # |> tap(&Enum.each(&1, fn %Task{pid: pid} -> send(pid, :start) end))
          |> Task.yield_many(
            timeout: :timer.seconds(20),
            on_timeout: :kill_task
          )
          |> Enum.map(fn
            {_task, {:ok, _result}} ->
              :ok

            other ->
              raise "Bad match " <> inspect(other, pretty: true)
          end)
        }
      end,
      before_scenario: fn %{mods: mods, msgs: msgs} ->
        server_id =
          "serv_#{S.random_string_weak(8)}"
          |> String.to_atom()

        cfg =
          SiteConfig.validate!(
            [
              service: :dummy,
              server_id: server_id,
              error_channel_id: :errors,
              plugs: mods
            ],
            Service.Dummy.site_config_schema()
          )

        user_id =
          "user_#{S.random_string_weak(8)}"
          |> String.to_atom()

        channel_id =
          "thread_#{S.random_string_weak(8)}"
          |> String.to_atom()

        tasks =
          msgs
          |> Enum.map_reduce(0, fn
            :ping, i ->
              {
                S.Msg.new(
                  body: "!ping",
                  server_id: server_id,
                  author_id: user_id,
                  channel_id: channel_id,
                  id: i,
                  service: Service.Dummy
                )
                |> S.Msg.add_context(cfg),
                i + 1
              }

            :unrelated, i ->
              {
                S.Msg.new(
                  body: "lololol",
                  server_id: server_id,
                  author_id: user_id,
                  channel_id: channel_id,
                  id: i,
                  service: Service.Dummy
                )
                |> S.Msg.add_context(cfg),
                i + 1
              }
          end)
          |> elem(0)
          |> Enum.map(
            &Task.async(fn ->
              msg = &1
              # receive do
              #  :start ->
              # IO.puts("Getting response for message #{msg.id}: #{msg.body}")
              response = Plugin.get_top_response(cfg, msg)
              # IO.puts("response for message #{msg.id}: #{inspect(response)}")
              case response do
                {%{text: "pong!"}, _iid} ->
                  if msg.body != "ping" do
                    raise "got pong when I shouldnt have"
                  end

                nil ->
                  if msg.body != "lololol" do
                    raise "didnt get response when I should have"
                  end
              end

              # end

              :ok
            end)
          )

        {cfg, tasks}
      end
    },
    "single threaded plugin processing" => {
      fn {cfg, msgs} ->
        {
          length(msgs),
          Task.async_stream(
            msgs,
            fn msg ->
              # IO.puts("Getting response for message #{msg.id}: #{msg.body}")
              response = T.stupid_get_top_response(cfg, msg)
              # IO.puts("response for message #{msg.id}: #{inspect(response)}")
              case response do
                %{text: "pong!"} ->
                  if msg.body != "ping" do
                    raise "got pong when I shouldnt have"
                  end

                nil ->
                  if msg.body != "lololol" do
                    raise "didnt get response when I should have"
                  end
              end

              :ok
            end,
            timeout: :timer.seconds(20),
            ordered: false,
            max_concurrency: 1000
          )
          |> Enum.to_list()
        }
      end,
      before_scenario: fn %{mods: mods, msgs: msgs} ->
        server_id =
          "serv_#{S.random_string_weak(8)}"
          |> String.to_atom()

        cfg =
          SiteConfig.validate!(
            [
              service: :dummy,
              server_id: server_id,
              error_channel_id: :errors,
              plugs: mods
            ],
            Service.Dummy.site_config_schema()
          )

        user_id =
          "user_#{S.random_string_weak(8)}"
          |> String.to_atom()

        channel_id =
          "thread_#{S.random_string_weak(8)}"
          |> String.to_atom()

        msgs =
          msgs
          |> Enum.map_reduce(0, fn
            :ping, i ->
              {
                S.Msg.new(
                  body: "!ping",
                  server_id: server_id,
                  author_id: user_id,
                  channel_id: channel_id,
                  id: i,
                  service: Service.Dummy
                )
                |> S.Msg.add_context(cfg),
                i + 1
              }

            :unrelated, i ->
              {
                S.Msg.new(
                  body: "lololol",
                  server_id: server_id,
                  author_id: user_id,
                  channel_id: channel_id,
                  id: i,
                  service: Service.Dummy
                )
                |> S.Msg.add_context(cfg),
                i + 1
              }
          end)
          |> elem(0)

        {cfg, msgs}
      end
    }
  },
  inputs: inputs,
  time: 20,
  memory_time: 3,
  pre_check: true
  # profile_after: true
)
