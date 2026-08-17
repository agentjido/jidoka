defmodule Jidoka.ContextWindow do
  @moduledoc """
  Pure, deterministic projection of a complete transcript into a bounded prompt.

  Projection removes only whole, oldest turn groups. The active turn and the
  configured number of recent completed turns are mandatory. If mandatory
  content does not fit, projection returns an error and no model call is made.
  The source `Jidoka.Agent.State` is never changed.
  """

  alias Jidoka.Agent
  alias Jidoka.ContextWindow.Policy
  alias Jidoka.Portable

  @doc "Projects prompt messages under the configured input budget."
  @spec project(map(), [Agent.Message.t()], [Agent.Message.t()], Policy.t(), String.t()) ::
          {:ok, map(), map()} | {:error, term(), map()}
  def project(prompt, prefix, transcript, %Policy{} = policy, active_request_id)
      when is_map(prompt) and is_list(prefix) and is_list(transcript) and is_binary(active_request_id) do
    groups = turn_groups(transcript)
    before_messages = prefix ++ transcript
    before_prompt = put_messages(prompt, before_messages)
    before_tokens = estimate_tokens(before_prompt, policy)

    {kept_groups, omitted_groups} = compact_groups(groups, prefix, prompt, policy, active_request_id)
    kept_messages = prefix ++ Enum.flat_map(kept_groups, & &1.messages)
    projected_prompt = put_messages(prompt, kept_messages)
    after_tokens = estimate_tokens(projected_prompt, policy)
    evidence = evidence(policy, groups, omitted_groups, before_messages, kept_messages, before_tokens, after_tokens)

    if fits?(after_tokens, policy.input_budget) do
      {:ok, projected_prompt, evidence}
    else
      overflow = %{evidence | status: :overflow}
      {:error, {:context_input_budget_exceeded, overflow}, overflow}
    end
  end

  @doc "Returns the deterministic estimated-token count for a prompt or value."
  @spec estimate_tokens(term(), Policy.t()) :: non_neg_integer()
  def estimate_tokens(value, %Policy{bytes_per_token: bytes_per_token}) do
    value
    |> Portable.project()
    |> estimable()
    |> canonical()
    |> Jason.encode!()
    |> byte_size()
    |> ceil_div(bytes_per_token)
  end

  defp compact_groups(groups, _prefix, _prompt, %Policy{input_budget: nil}, _active_request_id),
    do: {groups, []}

  defp compact_groups(groups, prefix, prompt, %Policy{} = policy, active_request_id) do
    active_index = Enum.find_index(groups, &(&1.request_id == active_request_id))
    mandatory_start = mandatory_start(groups, active_index, policy.minimum_recent_turns)
    retained_start = retained_group_start(groups, mandatory_start, prefix, prompt, policy)
    {omitted, kept} = Enum.split(groups, retained_start)
    {kept, omitted}
  end

  defp retained_group_start(groups, mandatory_start, prefix, prompt, policy) do
    base = prompt_message_stats(prompt, prefix)
    max_bytes = policy.input_budget * policy.bytes_per_token

    groups
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({length(groups), base}, fn {group, index}, {_retained_start, stats} ->
      candidate = append_message_stats(stats, message_stats(group.messages))

      if index >= mandatory_start or candidate.bytes <= max_bytes do
        {:cont, {index, candidate}}
      else
        {:halt, {index + 1, stats}}
      end
    end)
    |> elem(0)
  end

  defp prompt_message_stats(prompt, prefix) do
    empty_prompt_bytes = prompt |> put_messages([]) |> encoded_size()
    prefix_stats = message_stats(prefix)
    %{prefix_stats | bytes: empty_prompt_bytes - 2 + 2 + prefix_stats.bytes}
  end

  defp message_stats(messages) do
    {bytes, count} =
      Enum.reduce(messages, {0, 0}, fn message, {bytes, count} ->
        separator = if count == 0, do: 0, else: 1
        {bytes + separator + encoded_size(Agent.Message.to_map(message)), count + 1}
      end)

    %{bytes: bytes, count: count}
  end

  defp append_message_stats(left, %{count: 0}), do: left

  defp append_message_stats(left, right) do
    separator = if left.count == 0, do: 0, else: 1
    %{bytes: left.bytes + separator + right.bytes, count: left.count + right.count}
  end

  defp encoded_size(value) do
    value
    |> Portable.project()
    |> estimable()
    |> canonical()
    |> Jason.encode!()
    |> byte_size()
  end

  defp mandatory_start(groups, active_index, minimum_recent_turns) do
    history_count = active_index || length(groups)
    max(history_count - minimum_recent_turns, 0)
  end

  defp turn_groups(messages) do
    {groups, _legacy_index, _current_key} =
      Enum.reduce(messages, {[], 0, nil}, fn message, {groups, legacy_index, current_key} ->
        {key, legacy_index} = group_key(message, legacy_index, current_key)
        {append_group(groups, key, message), legacy_index, key}
      end)

    groups
  end

  defp group_key(%Agent.Message{request_id: request_id}, legacy_index, _current_key)
       when is_binary(request_id),
       do: {request_id, legacy_index}

  defp group_key(%Agent.Message{role: :user}, legacy_index, _current_key) do
    next = legacy_index + 1
    {"legacy:#{next}", next}
  end

  defp group_key(%Agent.Message{}, legacy_index, nil), do: {"legacy:#{legacy_index}", legacy_index}
  defp group_key(%Agent.Message{}, legacy_index, current_key), do: {current_key, legacy_index}

  defp append_group([], request_id, message), do: [%{request_id: request_id, messages: [message]}]

  defp append_group(groups, request_id, message) do
    case List.last(groups) do
      %{request_id: ^request_id} = group ->
        List.replace_at(groups, -1, %{group | messages: group.messages ++ [message]})

      _group ->
        groups ++ [%{request_id: request_id, messages: [message]}]
    end
  end

  defp put_messages(prompt, messages) do
    Map.put(prompt, :messages, Enum.map(messages, &Agent.Message.to_map/1))
  end

  defp evidence(policy, groups, omitted, before, after_messages, before_tokens, after_tokens) do
    omitted_messages = Enum.flat_map(omitted, & &1.messages)

    %{
      status: if(omitted == [], do: :complete, else: :compacted),
      estimator: :utf8_bytes_divided_by_configured_ratio,
      input_budget: policy.input_budget,
      output_reserve: policy.output_reserve,
      minimum_recent_turns: policy.minimum_recent_turns,
      bytes_per_token: policy.bytes_per_token,
      estimated_input_tokens_before: before_tokens,
      estimated_input_tokens_after: after_tokens,
      turn_count_before: length(groups),
      turn_count_after: length(groups) - length(omitted),
      message_count_before: length(before),
      message_count_after: length(after_messages),
      omitted_turn_ids: Enum.map(omitted, & &1.request_id),
      omitted_message_count: length(omitted_messages),
      omitted_digest: digest(omitted_messages)
    }
  end

  defp digest([]), do: nil

  defp digest(messages) do
    messages
    |> Enum.map(&Agent.Message.to_map/1)
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> [canonical_key(key), canonical(value)] end)
    |> Enum.sort_by(&hd/1)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> canonical()
  defp canonical(value), do: value

  defp estimable(value) when is_pid(value), do: "[runtime:pid]"
  defp estimable(value) when is_port(value), do: "[runtime:port]"
  defp estimable(value) when is_reference(value), do: "[runtime:reference]"
  defp estimable(value) when is_function(value), do: "[runtime:function]"

  defp estimable(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> estimable()
  end

  defp estimable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {estimable(key), estimable(value)} end)
  end

  defp estimable(list) when is_list(list), do: Enum.map(list, &estimable/1)
  defp estimable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> estimable()
  defp estimable(value) when is_atom(value), do: Atom.to_string(value)
  defp estimable(value), do: value

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key), do: inspect(key)

  defp fits?(_tokens, nil), do: true
  defp fits?(tokens, budget), do: tokens <= budget

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
