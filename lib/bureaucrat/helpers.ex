defmodule Bureaucrat.Helpers do
  alias Phoenix.Socket.{Broadcast, Message, Reply}
  alias Phoenix.Socket

  @doc """
  Adds a conn to the generated documentation.

  The name of the test currently being executed will be used as a description for the example.
  """
  defmacro doc(conn) do
    quote bind_quoted: [conn: conn] do
      doc(conn, [])
    end
  end

  @doc """
  Adds a Phoenix.Socket connection to the generated documentation.

  The name of the test currently being executed will be used as a description for the example.
  """
  defmacro doc_connect(
             handler,
             params,
             connect_info \\ quote(do: %{})
           ) do
    if endpoint = Module.get_attribute(__CALLER__.module, :endpoint) do
      quote do
        {status, socket} =
          unquote(Phoenix.ChannelTest).__connect__(unquote(endpoint), unquote(handler), unquote(params), unquote(connect_info))

        doc({status, socket, unquote(handler), unquote(params), unquote(connect_info)})
        {status, socket}
      end
    else
      raise "module attribute @endpoint not set for socket/2"
    end
  end

  @doc """
  Adds a Phoenix.Socket.Message to the generated documentation.

  The name of the test currently being executed will be used as a description for the example.
  """
  defmacro doc_push(socket, event) do
    quote bind_quoted: [socket: socket, event: event] do
      ref = make_ref()
      message = %Message{event: event, topic: socket.topic, ref: ref, payload: Phoenix.ChannelTest.__stringify__(%{})}
      doc(message, [])
      send(socket.channel_pid, message)
      ref
    end
  end

  defmacro doc_push(socket, event, payload) do
    quote bind_quoted: [socket: socket, event: event, payload: payload] do
      ref = make_ref()
      message = %Message{event: event, topic: socket.topic, ref: ref, payload: Phoenix.ChannelTest.__stringify__(payload)}
      doc(message, [])
      send(socket.channel_pid, message)
      ref
    end
  end

  defmacro doc_broadcast_from(socket, event, message) do
    quote bind_quoted: [socket: socket, event: event, message: message] do
      %{pubsub_server: pubsub_server, topic: topic, transport_pid: transport_pid} = socket
      broadcast = %Broadcast{topic: topic, event: event, payload: message}
      doc(broadcast, [])
      Phoenix.Channel.Server.broadcast_from(pubsub_server, transport_pid, topic, event, message)
    end
  end

  defmacro doc_broadcast_from!(socket, event, message) do
    quote bind_quoted: [socket: socket, event: event, message: message] do
      %{pubsub_server: pubsub_server, topic: topic, transport_pid: transport_pid} = socket
      broadcast = %Broadcast{topic: topic, event: event, payload: message}
      doc(broadcast, [])
      Phoenix.Channel.Server.broadcast_from!(pubsub_server, transport_pid, topic, event, message)
    end
  end

  @doc """
  Adds a conn to the generated documentation

  The description, and additional options can be passed in the second argument:

  ## Examples

      conn = conn()
        |> get("/api/v1/products")
        |> doc("List all products")

      conn = conn()
        |> get("/api/v1/products")
        |> doc(description: "List all products", operation_id: "list_products")
  """
  defmacro doc(conn, desc) when is_binary(desc) do
    quote bind_quoted: [conn: conn, desc: desc] do
      doc(conn, description: desc)
    end
  end

  defmacro doc(conn, opts) when is_list(opts) do
    # __CALLER__returns a `Macro.Env` struct
    #   -> https://hexdocs.pm/elixir/Macro.Env.html
    mod = __CALLER__.module
    fun = __CALLER__.function |> elem(0) |> to_string
    # full path as binary
    file = __CALLER__.file
    line = __CALLER__.line

    titles = Application.get_env(:bureaucrat, :titles)

    opts =
      opts
      |> Keyword.put_new(:group_title, group_title_for(mod, titles))
      |> Keyword.put(:module, mod)
      |> Keyword.put(:file, file)
      |> Keyword.put(:line, line)

    quote bind_quoted: [conn: conn, opts: opts, fun: fun] do
      default_operation_id = get_default_operation_id(conn)

      opts =
        opts
        |> Keyword.put_new(:description, format_test_name(conn, fun))
        |> Keyword.put_new(:operation_id, default_operation_id)

      Bureaucrat.Recorder.doc(conn, opts)
      conn
    end
  end

  def format_test_name(conn, "test " <> name) do
    if Application.get_env(:bureaucrat, :routes_as_titles) do
      method = conn.method |> to_string() |> String.upcase()
      router_path = Phoenix.Router.route_info(conn.private[:phoenix_router], method, conn.request_path, conn.host)
      "#{method} #{router_path[:route]}"
    else
      name
    end
  end

  def format_test_name(function_name) do
    raise """
    It looks like you called a `Phoenix.ConnTest` macro inside `#{function_name}`.
    Bureaucrat can only document macros `get`, `post`, `delete`, etc. when they are called inside a `test` block.

    If the request macro is called inside a private function or setup, you should explicitly say you don't want Bureaucrat to document this request.
    Use `get_undocumented`, `post_undocumented`, `delete_undocumented`, `patch_undocumented` or `put_undocumented` instead.
    """
  end

  def group_title_for(_mod, []), do: nil

  def group_title_for(mod, [{other, path} | paths]) do
    if String.replace_suffix(to_string(mod), "Test", "") == to_string(other) do
      path
    else
      group_title_for(mod, paths)
    end
  end

  def get_default_operation_id(%Plug.Conn{private: private}) do
    case private do
      %{phoenix_controller: elixir_controller, phoenix_action: action} ->
        "#{inspect(elixir_controller)}.#{action}"

      _ ->
        raise """
        Bureaucrat couldn't find a controller and/or action for this request.
        Possibly, the request is halted by a plug before it gets to the controller.
        Please use `get_undocumented` or `post_undocumented` (etc.) instead.
        """
    end
  end

  def get_default_operation_id(%Message{topic: topic, event: event}) do
    "#{topic}.#{event}"
  end

  def get_default_operation_id(%Broadcast{topic: topic, event: event}) do
    "#{topic}.#{event}"
  end

  def get_default_operation_id(%Reply{topic: topic}) do
    "#{topic}.reply"
  end

  def get_default_operation_id({_, _, %Socket{endpoint: endpoint}}) do
    "#{endpoint}.reply"
  end

  def get_default_operation_id({_, %Socket{endpoint: endpoint}, _, _, _}) do
    "#{endpoint}.connect"
  end

  @doc """
  Helper function for adding the phoenix_controller and phoenix_action keys to
  the private map of the request that's coming from the test modules.

  For example:

  test "all items - unauthenticated", %{conn: conn} do
    conn
    |> get(item_path(conn, :index))
    |> plug_doc(module: __MODULE__, action: :index)
    |> doc()
    |> assert_unauthenticated()
  end

  The request from this test will never touch the controller that's being tested,
  because it is being piped through a plug that authenticates the user and redirects
  to another page. In this scenario, we use the plug_doc function.
  """
  def plug_doc(conn, module: module, action: action) do
    controller_name = module |> to_string |> String.trim("Test")

    conn
    |> Plug.Conn.put_private(:phoenix_controller, controller_name)
    |> Plug.Conn.put_private(:phoenix_action, action)
  end

  def get_documentation_for_function(module, function) do
    docs =
      Code.fetch_docs(module)
      |> Tuple.to_list()
      |> Enum.at(6)
      |> Enum.find(fn
        {{_, ^function, _}, _, _, docs, _} when docs != :none -> true
        _ -> false
      end)

    if docs do
      docs
      |> Tuple.to_list()
      |> Enum.at(4)
      |> Map.get("en")
    else
      # NoDocs.add(module)
      # raise "No docs for #{module} #{function}"
      ""
    end
  end

  def controller_param_spec(controller, name \\ nil) do
    {:ok, spec} = Code.Typespec.fetch_specs(controller)

    {:ok, types} = Code.Typespec.fetch_types(controller)

    types = group_types(types)

    spec =
      if name do
        Enum.flat_map(spec, fn
          {{^name, _}, [{_, _, _, [{_, _, _, types} | _]}]} -> types
          _ -> []
        end)
      else
        spec
      end

    spec
    |> Enum.flat_map(fn
      {_, _, [{_, _, Plug.Conn}, _, _]} -> []
      {:remote_type, _, type_list} -> type_list
      {:user_type, _, name, []} -> types[name]
      other -> collect_types(other)
    end)
    |> normalize(types)
    |> to_table()
  end

  defp group_types(ast) do
    Enum.reduce(ast, %{}, fn {:type, {name, ast, _}}, acc ->
      Map.put(acc, name, collect_types(ast))
    end)
  end

  defp collect_types({:user_type, _, type}), do: type

  defp collect_types({_, _, map, fields}) when map in ~w/map_fields_exact map/a do
    fields
    |> Enum.map(fn
      {_, _, required, [{:atom, _, key}, {_, _, type_list}]} when is_list(type_list) ->
        {key, concat_type_list(type_list), required}

      {_, _, required, [{:atom, _, key}, {_, _, type}]} ->
        {key, type, required}

      {_, _, required, [{:atom, _, key}, {_, _, type, _}]} ->
        {key, type, required}
    end)
  end

  defp collect_types(_), do: nil
  defp concat_type_list([atom, other_atom]) when is_atom(atom) and is_atom(other_atom), do: to_string(atom)

  defp concat_type_list(type_list) when is_list(type_list) do
    type_list
    |> Enum.filter(&is_tuple/1)
    |> Enum.map(&elem(&1, 2))
  end

  defp concat_type_list(type_list), do: type_list

  defp normalize(list_of_types, types) do
    list_of_types
    |> Enum.map(fn {key, type, req} ->
      type = concat_type_list(type)
      user_type = types[type]
      required? = req == :map_field_exact
      {key, (user_type && normalize(user_type, types)) || type, required?}
    end)
  end

  def to_table(rows) do
    rows = Enum.map(rows, &to_row/1) |> Enum.join("\n")

    table = """
    <table>
      <thead>
        <tr>
          <th>Field</th>
          <th>Type</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """

    Regex.replace(~r/Elixir./, table, "")
  end

  defp to_row(row) when is_binary(row), do: row
  defp to_row({key, value}), do: "<tr><td>#{key}</td><td>#{value}</td></tr>"

  defp to_row({key, value, required?}),
    do:
      "<tr><td>#{(required? && "**") || ""}#{key}#{(required? && "**") || ""}</td><td>#{(is_list(value) && to_table(value)) || value}</td></tr>"
end
