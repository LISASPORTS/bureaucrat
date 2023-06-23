defmodule Bureaucrat.TypeCollector do
  use Agent
  import Bureaucrat.Helpers, only: [to_table: 1]

  defstruct schemas: %{}, modules: %{}

  def start_link(_) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  def register_types(modules) when is_map(modules) do
    for module <- Map.values(modules) do
      register_types(module)
    end
  end

  def register_types(module) do
    Agent.update(__MODULE__, fn state ->
      do_register_types(module, state)
    end)
  end

  defp do_register_types(module, state) do
    module_name = normalize_name(module)

    with {:ok, spec} <- Code.Typespec.fetch_specs(module),
         [schema | _] <- find_schema(spec),
         true <- is_nil(state.schemas[schema]) do
      types = get_view_types(module, schema)

      state = %{
        state
        | modules: Map.put(state.modules, module_name, schema),
          schemas: Map.put(state.schemas, schema, types)
      }

      # Register views that are used in other views but not directly in a controller
      Enum.reduce(types, state, fn
        {_key, val}, acc when is_atom(val) ->
          do_register_types(val, acc)

        _, acc ->
          acc
      end)
    else
      _ -> state
    end
  end

  def get_request_types(module, filter, action \\ :show) do
    module_name = normalize_name(module)

    Agent.get(__MODULE__, fn %{modules: modules} ->
      schema = modules[module_name]

      if schema do
        schema_attributes = schema.__info__(:attributes)

        required_fields = schema_attributes[:required_fields] || []
        optional_fields = schema_attributes[:optional_fields] || []
        allowed_fields = schema_attributes[:allowed_fields] || []

        fields =
          if action == :update do
            schema_attributes[:update_fields] || []
          else
            required_fields ++ optional_fields ++ allowed_fields
          end
          |> Enum.filter(fn field -> field not in filter end)
          |> Enum.uniq()
          |> Enum.sort()

        res =
          Enum.reduce(fields, "", fn key, acc ->
            required =
              (key in required_fields && "**required**") ||
                ""

            acc <> "    * #{key}: #{normalize_type(schema.__schema__(:type, key))} #{required} \n\n"
          end)

        res
      else
        ""
      end
    end)
  end

  def get_response_types(module, _filter, _action \\ :show) do
    module = json_view(module)
    module_name = normalize_name(module)

    Agent.get(__MODULE__, fn %{modules: modules} ->
      schema = modules[module_name]

      if schema do
        types = get_view_types(module, schema)
        textualize_types(types, modules)
      else
        ""
      end
    end)
  end

  def get_all_types() do
    Agent.get(__MODULE__, fn %{schemas: schemas, modules: modules} ->
      Enum.reduce(schemas, "", fn {schema, types}, acc ->
        schema = normalize_name(schema)
        acc <> "### <a id=#{schema}></a>#{schema}\n\n#{textualize_types(types, modules)}\n\n"
      end)
    end)
  end

  defp textualize_types(nil, _), do: ""

  defp textualize_types(types, modules) do
    Enum.map(types, &write_type(&1, modules))
    |> to_table()
  end

  defp get_view_types(%{_: view}, schema), do: get_view_types(view, schema)

  defp get_view_types(view, schema) do
    fields = view.__info__(:attributes)[:attributes]

    if fields do
      Enum.reduce(fields, %{}, fn
        {key, {view, _template}}, acc ->
          Map.put(acc, key, view)

        {_, {view, _template, key}}, acc ->
          Map.put(acc, key, view)

        key, acc ->
          key = (is_binary(key) && String.to_atom(key)) || key
          type = schema.__schema__(:type, key)
          Map.put(acc, key, normalize_type(type))
      end)
    else
      %{}
    end
  end

  defp find_schema(ast) do
    do_find_schema(ast)
    |> Enum.flat_map(fn
      nil -> []
      other -> [other]
    end)
  end

  defp do_find_schema(ast) do
    node =
      if not is_list(ast) do
        Tuple.to_list(ast) |> Enum.at(-1)
      else
        ast
      end

    case node do
      [{:atom, _, :__struct__}, {:atom, _, module}] ->
        [module]

      _ when is_list(ast) ->
        Enum.flat_map(ast, &find_schema/1)

      children when is_list(children) ->
        Enum.flat_map(children, &find_schema/1)

      _other ->
        [nil]
    end
  end

  defp normalize_type({:parameterized, _, %{on_dump: values}}) do
    Map.values(values)
    |> Enum.map_join(" \\| ", &"\"#{&1}\"")
  end

  defp normalize_type(:binary), do: "string"
  defp normalize_type(:id), do: "string"
  defp normalize_type(:utc_datetime_usec), do: "UTC Datetime with milliseconds"
  defp normalize_type(BillingEngine.Encrypted.Binary), do: "encrypted string"
  defp normalize_type(Money.Ecto.Amount.Type), do: "integer, in cents"
  defp normalize_type(type), do: to_string(type)

  defp write_type({key, type}, modules) when is_atom(type) do
    type_module = Map.get(modules, normalize_name(type)) |> normalize_name()
    "<tr><td>#{key}</td><td>[#{type_module}](##{type_module})</td></tr>"
  end

  defp write_type({{_, key}, value_type}, _) when is_function(key) do
    key = key |> Function.info() |> Keyword.get(:module)
    "<tr><td>#{key}</td><td>#{value_type}</td></tr>"
  end

  defp write_type({key, value_type}, _), do: "<tr><td>#{key}</td><td>#{value_type}</td></tr>"

  defp json_view(%{"json" => module}), do: module
  defp json_view(module), do: module

  defp normalize_name(%{_: module}), do: normalize_name(module)
  defp normalize_name(module), do: module |> Module.split() |> Enum.at(-1)
end
