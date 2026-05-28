defmodule Jidoka.Agent.Compiler.Context do
  @moduledoc false

  @enforce_keys [:env, :owner_module]
  defstruct [
    :env,
    :owner_module,
    :agent,
    values: %{},
    public_fields: %{},
    generated_modules: [],
    runtime_hooks: %{},
    imported_spec: %{},
    trace_names: %{},
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          env: Macro.Env.t(),
          owner_module: module(),
          agent: term(),
          values: map(),
          public_fields: map(),
          generated_modules: [module()],
          runtime_hooks: map(),
          imported_spec: map(),
          trace_names: map(),
          diagnostics: [term()]
        }

  @spec new(Macro.Env.t(), keyword() | map()) :: t()
  def new(%Macro.Env{} = env, opts \\ []) do
    opts = if is_list(opts), do: Map.new(opts), else: opts

    %__MODULE__{
      env: env,
      owner_module: Map.get(opts, :owner_module, env.module),
      agent: Map.get(opts, :agent),
      values: Map.get(opts, :values, %{}),
      public_fields: Map.get(opts, :public_fields, %{}),
      generated_modules: Map.get(opts, :generated_modules, []),
      runtime_hooks: Map.get(opts, :runtime_hooks, %{}),
      imported_spec: Map.get(opts, :imported_spec, %{}),
      trace_names: Map.get(opts, :trace_names, %{}),
      diagnostics: Map.get(opts, :diagnostics, [])
    }
  end

  @spec put_value(t(), atom(), term()) :: t()
  def put_value(%__MODULE__{} = context, key, value) when is_atom(key) do
    put_in(context.values[key], value)
  end

  @spec merge_values(t(), map()) :: t()
  def merge_values(%__MODULE__{} = context, values) when is_map(values) do
    %{context | values: Map.merge(context.values, values)}
  end

  @spec merge_public_fields(t(), map()) :: t()
  def merge_public_fields(%__MODULE__{} = context, fields) when is_map(fields) do
    %{context | public_fields: Map.merge(context.public_fields, fields)}
  end

  @spec add_generated_module(t(), module()) :: t()
  def add_generated_module(%__MODULE__{} = context, module) when is_atom(module) do
    %{context | generated_modules: append_unique(context.generated_modules, module)}
  end

  @spec put_runtime_hook(t(), atom(), term()) :: t()
  def put_runtime_hook(%__MODULE__{} = context, key, value) when is_atom(key) do
    put_in(context.runtime_hooks[key], value)
  end

  @spec merge_imported_spec(t(), map()) :: t()
  def merge_imported_spec(%__MODULE__{} = context, spec) when is_map(spec) do
    %{context | imported_spec: deep_merge(context.imported_spec, spec)}
  end

  @spec put_trace_name(t(), atom(), String.t()) :: t()
  def put_trace_name(%__MODULE__{} = context, key, value) when is_atom(key) and is_binary(value) do
    put_in(context.trace_names[key], value)
  end

  @spec add_diagnostic(t(), term()) :: t()
  def add_diagnostic(%__MODULE__{} = context, diagnostic) do
    %{context | diagnostics: context.diagnostics ++ [diagnostic]}
  end

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, %{} = left_value, %{} = right_value ->
      deep_merge(left_value, right_value)
    end)
  end
end
