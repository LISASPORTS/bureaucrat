defmodule Bureaucrat.Recorder do
  use GenServer

  alias Phoenix.Socket
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  def start_link([]) do
    {:ok, _} = GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def doc(%Broadcast{} = broadcast, opts) do
    GenServer.cast(__MODULE__, {:channel_doc, broadcast, opts})
  end

  def doc(%Message{} = message, opts) do
    GenServer.cast(__MODULE__, {:channel_doc, message, opts})
  end

  def doc(%Reply{} = reply, opts) do
    GenServer.cast(__MODULE__, {:channel_doc, reply, opts})
  end

  def doc({_, _, %Socket{}} = join_socket, opts) do
    GenServer.cast(__MODULE__, {:channel_doc, join_socket, opts})
  end

  def doc({_, %Socket{}, _, _, _} = connect_socket, opts) do
    GenServer.cast(__MODULE__, {:channel_doc, connect_socket, opts})
  end

  def doc(conn, opts) do
    GenServer.cast(__MODULE__, {:doc, conn, opts})
  end

  def get_records do
    GenServer.call(__MODULE__, :get_records)
  end

  def init([]) do
    {:ok, []}
  end

  def handle_cast({:doc, conn, opts}, records) do
    cond do
      conn.status == 401 ->
        {:noreply, records}

      conn.status not in [200, 201] ->
        {:noreply, records}

      route_exists?(records, conn) ->
        {:noreply, records}

      true ->
        view = conn.private[:phoenix_view]
        Bureaucrat.TypeCollector.register_types(view)

        conn =
          conn
          |> Plug.Conn.assign(:bureaucrat_desc, opts[:description])
          |> Plug.Conn.assign(:bureaucrat_file, opts[:file])
          |> Plug.Conn.assign(:bureaucrat_line, opts[:line])
          |> Plug.Conn.assign(:bureaucrat_opts, opts)

        {:noreply, [conn | records]}
    end
  end

  def handle_cast({:channel_doc, message, opts}, records) do
    {:noreply, [{message, opts} | records]}
  end

  def handle_call(:get_records, _from, records) do
    {:reply, records, records}
  end

  defp route_exists?(records, conn) do
    conn_route_info = Phoenix.Router.route_info(conn.private[:phoenix_router], conn.method, conn.request_path, conn)

    Enum.find(records, fn record ->
      record_route_info = Phoenix.Router.route_info(record.private[:phoenix_router], record.method, record.request_path, record)
      record_route_info.route == conn_route_info.route && record_route_info.plug_opts == conn_route_info.plug_opts
    end)
  end
end
