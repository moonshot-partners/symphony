defmodule SymphonyElixir.Orchestrator.AgentAction do
  @moduledoc """
  Renders one agent stream update into a short, human one-liner for the
  cockpit — the "last action" on the `/live` snapshot and each row of the
  live event timeline.

  The input is either a plain string or the `AgentUpdate.summarize_update/1`
  map (`%{event, message, timestamp}`) whose `message` is the raw agent
  stream payload. The shim sends JSON-RPC for each block in a turn:

    * `item/commandExecution/requestApproval` -> `params.command` (a bash run)
    * `item/fileChange/requestApproval` -> `params.path` (a file write)
    * `item/agent_message` -> `params.text` (assistant prose)
    * `turn/completed` and friends -> the method name

  We surface the most specific thing each payload carries, falling back to
  the method's last segment and then the event tag, and always return a
  string (clipped to 80 chars) or nil — never a raw map, which would 502 the
  JSON-safe `/live` contract.
  """

  @max_len 80

  @spec line(map() | binary() | nil) :: binary() | nil
  def line(text) when is_binary(text), do: clip(text)

  def line(%{} = summary) do
    message = Map.get(summary, :message) || Map.get(summary, "message")
    event = Map.get(summary, :event) || Map.get(summary, "event")
    from_message(message) || stringify(event)
  end

  def line(_), do: nil

  defp from_message(%{"params" => %{"command" => cmd}}) when is_binary(cmd),
    do: "Running " <> clip(first_line(cmd))

  defp from_message(%{"params" => %{"path" => path}}) when is_binary(path) and path != "",
    do: "Editing " <> clip(Path.basename(path))

  defp from_message(%{"params" => %{"text" => text}}) when is_binary(text) and text != "",
    do: clip(first_line(text))

  defp from_message(%{"method" => method}) when is_binary(method),
    do: method |> String.split("/") |> List.last()

  defp from_message(text) when is_binary(text) and text != "", do: clip(text)
  defp from_message(_), do: nil

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> List.first()

  defp clip(text) when is_binary(text) do
    if String.length(text) > @max_len, do: String.slice(text, 0, @max_len - 1) <> "…", else: text
  end

  defp stringify(nil), do: nil
  defp stringify(event), do: to_string(event)
end
