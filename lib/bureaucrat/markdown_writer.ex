defmodule Bureaucrat.MarkdownWriter do
  alias Bureaucrat.{Helpers, JSON, TypeCollector}

  def write(records, path) do
    {:ok, file} = File.open(path, [:write, :utf8])
    records = group_records(records)

    file
    |> puts(~s[<link rel="stylesheet" href="https://unpkg.com/@picocss/pico@1.*/css/pico.min.css">\n])
    |> puts("""
    <style>
       :root {
        --font-size: 12px
       }
       body {
        display: grid;
        grid-template-columns: 1fr 4fr;
        grid-template-areas: "aside main main main";
        grid-gap: 10px;
        height: 100%
        }
       aside {
        grid-area: aside;
        margin-top: 1em;
        border-right: 1px #eee solid;
        }
       main {
        grid-area: main;
        overflow-y: scroll;
        }
    </style>
    """)

    write_table_of_contents(records, file)

    file
    |> puts(~s[<main class="container">\n])

    write_intro(path, file)

    types = TypeCollector.get_all_types()

    file
    |> puts("## Types\n\n#{types}")

    Enum.each(records, fn {controller, records} ->
      write_controller(controller, records, file)
    end)

    file
    |> puts(~s[</main>\n])
  end

  defp write_intro(path, file) do
    intro_file_path =
      [
        # /path/to/API.md -> /path/to/API_INTRO.md
        String.replace(path, ~r/\.md$/i, "_INTRO\\0"),
        # /path/to/api.md -> /path/to/api_intro.md
        String.replace(path, ~r/\.md$/i, "_intro\\0"),
        # /path/to/API -> /path/to/API_INTRO
        "#{path}_INTRO",
        # /path/to/api -> /path/to/api_intro
        "#{path}_intro"
      ]
      # which one exists?
      |> Enum.find(nil, &File.exists?/1)

    if intro_file_path do
      file
      |> puts(File.read!(intro_file_path))
      |> puts("\n\n## Endpoints\n\n")
    else
      puts(file, "# API Documentation\n\n")
    end
  end

  defp write_table_of_contents(records, file) do
    file
    |> puts(~s[<aside><section>])

    records
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {controller, actions} ->
      actions = List.flatten(actions)
      anchor = to_anchor(controller)

      controller =
        controller
        |> String.split(".")
        |> Enum.at(-1)
        |> to_string()
        |> String.replace("Controller", "")

      puts(file, " * #### [#{controller}](##{anchor})")

      Enum.each(actions, fn {action, _} ->
        anchor = to_anchor(controller, action)
        puts(file, "   * [#{action}](##{anchor})")
      end)
    end)

    file
    |> puts("")
    |> puts(~s[</section></aside>])
  end

  defp write_controller(controller, records, file) do
    anchor = to_anchor(controller)
    puts(file, "## <a id=#{anchor}></a>#{controller}")

    Enum.each(records, fn {action, records} ->
      write_action(action, controller, records, file)
    end)
  end

  defp write_action(action, controller, records, file) do
    anchor = to_anchor(controller, action)
    puts(file, "### <a id=#{anchor}></a>#{action}")
    Enum.each(records, &write_example(&1, file))
  end

  defp write_example({%Phoenix.Socket.Broadcast{topic: topic, payload: payload, event: event}, _}, file) do
    file
    |> puts("#### Broadcast")
    |> puts("* __Topic:__ #{topic}")
    |> puts("* __Event:__ #{event}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({%Phoenix.Socket.Message{topic: topic, payload: payload, event: event}, _}, file) do
    file
    |> puts("#### Message")
    |> puts("* __Topic:__ #{topic}")
    |> puts("* __Event:__ #{event}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({%Phoenix.Socket.Reply{payload: payload, status: status}, _}, file) do
    file
    |> puts("#### Reply")
    |> puts("* __Status:__ #{status}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({{status, payload, %Phoenix.Socket{} = socket}, _}, file) do
    file
    |> puts("#### Join")
    |> puts("* __Topic:__ #{socket.topic}")
    |> puts("* __Receive:__ #{status}")

    if payload != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(payload)}")
      |> puts("```")
    end
  end

  defp write_example({{status, %Phoenix.Socket{}, _handler, params, _connect_info}, _}, file) do
    # for connect
    file
    |> puts("#### Connect")

    if params != %{} do
      file
      |> puts("* __Body:__")
      |> puts("```json")
      |> puts("#{format_body_params(params)}")
      |> puts("```")
    end
    |> puts("* __Receive:__ #{status}")
  end

  defp write_example(record, file) do
    view = record.private[:phoenix_view]
    controller = record.private[:phoenix_controller]

    route_info = Phoenix.Router.route_info(record.private[:phoenix_router], record.method, record.request_path, record)

    documentation = Helpers.get_documentation_for_function(controller, route_info[:plug_opts])

    file
    |> puts("#### #{record.assigns.bureaucrat_desc}")
    |> puts("#{Keyword.get(record.assigns.bureaucrat_opts, :detail, "")}")
    |> puts(documentation)
    |> puts("##### Request")
    |> puts("* __Method:__ #{record.method}")
    |> puts("* __Path:__ #{route_info.route}")

    unless route_info.plug_opts not in ~w/create update process/a do
      file
      |> puts("* __Request body types:__ \n\n")
      |> puts("Fields marked in **bold** are required.\n\n")
      |> puts(Helpers.controller_param_spec(controller, route_info.plug_opts))
    end

    unless record.req_headers == [] do
      file
      |> puts("* __Request headers:__")
      |> puts("```")

      Enum.each(record.req_headers, fn {header, value} ->
        puts(file, "#{header}: #{value}")
      end)

      file
      |> puts("```")
    end

    unless record.body_params == %{} do
      file
      |> puts("* __Request body:__")
      |> puts("```json")
      |> puts("#{format_body_params(record.body_params)}")
      |> puts("```")
    end

    file
    |> puts("")
    |> puts("##### Response")
    |> puts("* __Status__: #{record.status}")

    unless record.resp_headers == [] do
      file
      |> puts("* __Response headers:__")
      |> puts("```")

      Enum.each(record.resp_headers, fn {header, value} ->
        puts(file, "#{header}: #{value}")
      end)

      file
      |> puts("```")
    end

    file
    |> puts("* __Response body:__ \n\n")
    |> puts(TypeCollector.get_response_types(view, %{}, route_info.plug_opts))
    |> puts("###### Example")
    |> puts("```json")
    |> puts("#{format_resp_body(record.resp_body)}")
    |> puts("```")
    |> puts("")
  end

  def format_body_params(params) do
    {:ok, json} = JSON.encode(params, pretty: true)
    json
  end

  defp format_resp_body("") do
    ""
  end

  defp format_resp_body(string) do
    case JSON.decode(string) do
      {:ok, struct} ->
        {:ok, json} = JSON.encode(struct, pretty: true)

        json

      {:error, %{data: data}} ->
        data
    end
  end

  defp puts(file, string) do
    IO.puts(file, string)
    file
  end

  defp strip_ns(module) do
    case to_string(module) do
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp to_anchor(controller, action), do: to_anchor("#{controller}.#{action}")

  defp to_anchor(name) do
    name
    |> String.downcase()
    |> String.replace(~r/\W+/, "-")
    |> String.replace_leading("-", "")
    |> String.replace_trailing("-", "")
  end

  defp group_records(records) do
    by_controller = Bureaucrat.Util.stable_group_by(records, &get_controller/1)

    Enum.map(by_controller, fn {c, recs} ->
      {c, Bureaucrat.Util.stable_group_by(recs, &get_action/1)}
    end)
  end

  defp get_controller({_, opts}), do: opts[:group_title] || String.replace_suffix(strip_ns(opts[:module]), "Test", "")
  defp get_controller(conn), do: conn.assigns.bureaucrat_opts[:group_title] || strip_ns(conn.private.phoenix_controller)

  defp get_action({_, opts}), do: opts[:description]
  defp get_action(conn), do: conn.private.phoenix_action
end
