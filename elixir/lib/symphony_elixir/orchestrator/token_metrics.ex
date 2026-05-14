defmodule SymphonyElixir.Orchestrator.TokenMetrics do
  @moduledoc """
  Pure helpers for extracting token usage deltas and rate-limit payloads from
  agent update events.

  Extracted from `SymphonyElixir.Orchestrator`. All callsites in the
  orchestrator GenServer delegate here; the module is side-effect free and
  testable without `*_for_test` shims.

  Public surface:

    * `extract_token_delta/2` — returns the input/output/total deltas for a
      single agent update, given the prior `running_entry` and the new event.
    * `extract_rate_limits/1` — locates a rate-limits payload inside an update
      event, handling the several shapes returned by Anthropic / Claude Agent
      SDK and any nested `params.payload` wrappers.
    * `token_delta_guard/3` — returns `:ok` while the running total has not
      crossed the threshold above a baseline, or `{:halt, info}` once it has.

  Everything else is private detail (payload traversal, integer coercion,
  shape detection for token/rate-limit maps).

  ## Token Delta Guard

  `token_delta_guard/3` is the pure decision helper behind the orchestrator's
  150k-tokens-since-last-PASS halt rule. The caller tracks a `baseline`
  (running total at the most recent PASS verdict) and the current
  `running_total`; the guard signals `{:halt, info}` strictly above the
  threshold so a value exactly at the threshold still counts as "headroom
  remaining". Baselines greater than the running total are clamped to zero —
  a backwards-moving running total is a caller-side accounting glitch, not a
  token burn, and must not trip the guard.
  """

  @default_token_delta_threshold 150_000

  @type guard_halt_info :: %{
          running_total: non_neg_integer(),
          baseline: non_neg_integer(),
          delta: non_neg_integer(),
          threshold: pos_integer()
        }

  @doc """
  Decides whether the running token total has exceeded `threshold` tokens
  above the `baseline` captured at the last PASS verdict.

  Returns `:ok` while the delta (`running_total - baseline`, clamped to zero)
  is at or below the threshold; returns `{:halt, info}` once the delta is
  strictly greater. The halt payload carries `running_total`, `baseline`,
  `delta` and `threshold` for the caller to log / surface to the operator.

  The default threshold is `#{@default_token_delta_threshold}` tokens, matching
  the documented Token Delta Guard from the orchestrator behavior contract.
  """
  @spec token_delta_guard(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          :ok | {:halt, guard_halt_info()}
  def token_delta_guard(running_total, baseline, threshold \\ @default_token_delta_threshold)
      when is_integer(running_total) and running_total >= 0 and
             is_integer(baseline) and baseline >= 0 and
             is_integer(threshold) and threshold > 0 do
    delta = max(running_total - baseline, 0)

    if delta > threshold do
      {:halt,
       %{
         running_total: running_total,
         baseline: baseline,
         delta: delta,
         threshold: threshold
       }}
    else
      :ok
    end
  end

  @doc """
  Extracts the input/output/total token delta from `update`, using
  `running_entry` to derive the previously-reported counters.

  Returns a map with `:input_tokens`, `:output_tokens`, `:total_tokens` and
  the `:input_reported`, `:output_reported`, `:total_reported` running totals
  for the caller to persist on the next entry.

  When the underlying SDK omits `total_tokens` (Anthropic), the total is
  derived as `input + output`.
  """
  @spec extract_token_delta(map() | nil, map()) :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          input_reported: non_neg_integer(),
          output_reported: non_neg_integer(),
          total_reported: non_neg_integer()
        }
  def extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(running_entry, :input, usage, :agent_last_reported_input_tokens),
      compute_token_delta(running_entry, :output, usage, :agent_last_reported_output_tokens),
      compute_token_delta(running_entry, :total, usage, :agent_last_reported_total_tokens)
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      effective_total =
        if is_nil(get_token_usage(usage, :total)) do
          %{delta: input.delta + output.delta, reported: input.reported + output.reported}
        else
          total
        end

      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: effective_total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: effective_total.reported
      }
    end)
  end

  @doc """
  Locates a rate-limits payload inside `update`, walking through the
  several shapes the Anthropic / Claude Agent SDK emits (direct map,
  `params.payload` wrappers, nested under `:rate_limits` / "rate_limits").

  Returns the rate-limits map when found, otherwise `nil`.
  """
  @spec extract_rate_limits(map()) :: map() | nil
  def extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
