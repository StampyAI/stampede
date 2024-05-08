alias Stampede, as: S
require Stampede.Msg

defmodule T do
  require Plugin
  require Aja

  def make_fake_modules(num, lagginess) when is_integer(num) and num > 0 do
    lag_max = ((lagginess == :slow && 500) || 10)
    Enum.reduce(0..num, MapSet.new(), fn i, acc ->
      name = Module.concat(Plugin, "fake_#{i}")

      lag = ((Float.pow(1.5, -i) * lag_max) |> round())
      IO.puts("This lag: #{lag |> to_string()}")

      contents =
        quote do
          use Plugin

          def query(cfg, msg) do
            Process.sleep(unquote(lag * 0.1 |> round()))
            Plugin.Test.query(cfg, msg)
          end

          def respond(arg) do
            Process.sleep(unquote(lag + 10))

            Plugin.Test.respond(arg)
            |> then(fn
              m when is_map(m) ->
                Map.put(m, :origin_plug, __MODULE__)

              other ->
                other
            end)
          end
        end

      if not Code.loaded?(name) do
        Module.create(name, contents, Macro.Env.location(__ENV__))
        Code.ensure_loaded!(name)
      end

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
    |> Aja.Vector.new()
  end

  def stupid_get_top_response(cfg, msg) do
    if Plugin.is_bot_needed(cfg, msg) do
      {
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
        |> Map.fetch!(:r),
        :no_interaction
      }
    else
      nil
    end
  end

  def make_run_tasks(name, query_func) do
    fn {cfg, msgs, super_name, max_concurrency} ->

      results = Task.Supervisor.async_stream(super_name, msgs, fn msg ->
        response = query_func.(cfg, msg)

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

        :ok
      end, timeout: :timer.seconds(20), max_concurrency: max_concurrency, ordered: false, on_timeout: :exit)
      |> Enum.to_list()

      {
        Aja.vec_size(msgs),
        results
      }
  end
  end

  def make_before_scenario() do
    fn %{mods: mods, msgs: msgs, max_concurrency: max_concurrency} ->
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
        |> Aja.Vector.map_reduce(0, fn
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

      super_name = :testing_super

      {cfg, msgs, super_name, max_concurrency}
    end
  end
end

{:ok, _} = Task.Supervisor.start_link(name: :testing_super)

inputs = %{
  "20 slow modules, 100 messages at 1/3, 32 divisions" => %{
    mods: T.make_fake_modules(20, :slow),
    msgs: T.make_messages(100, 3),
    max_concurrency: 32
  },
}

suites = %{
  "Current plugin processing code" => {
    T.make_run_tasks("current", &Plugin.get_top_response/2),
    before_scenario: T.make_before_scenario()
  }
}

Stampede.ensure_app_ready!()

apply_trace = fn f ->
  :eflame.apply(
    :normal_with_children,
    "./eflame/",
    f,
    []
  )
end

ef_opts = [
  {:output_directory, "./eflame/"},
  {:output_format, :svg},
  :value
]

#Application.ensure_loaded(:eflambe_app)

#spawn(fn -> :eflambe.capture({Plugin, :query_plugins, 3}, 100, ef_opts) end)
# :eflame.capture {Stampede.Interact, :prepare_interaction, 1}, 100, ef_opts
# :eflame.capture {Stampede, :fulfill_predicate_before_time, 2}, 1000, ef_opts

suites
|> Map.fetch!("Current plugin processing code")
|> elem(1)
|> Keyword.fetch!(:before_scenario)
|> tap(fn _ -> IO.puts("scenario prep") end)
|> then(fn f ->
  f.(%{
    mods: T.make_fake_modules(1, :slow),
    msgs: T.make_messages(2, 3),
    max_concurrency: 32
  }
  )
end)
|> tap(fn _ -> IO.puts("actual job") end)
|> then(fn before_scenario_result ->
  suites
  |> Map.fetch!("Current plugin processing code")
  |> elem(0)
  |> then(fn f ->
    f.(before_scenario_result)
  end)
end)

# :eflame.capture({Plugin, :query_plugins, 3}, 100, ef_opts)
#Benchee.run(
#  suites,
#  inputs: inputs,
#  time: 20,
#  # memory_time: 3,
#  pre_check: true
#  # profile_after: true
#)
