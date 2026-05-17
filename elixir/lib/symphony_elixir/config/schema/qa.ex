defmodule SymphonyElixir.Config.Schema.Qa do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @default_evidence_subpaths ["fe-next-app/qa-evidence"]

  @primary_key false
  embedded_schema do
    field(:evidence_subpaths, {:array, :string}, default: @default_evidence_subpaths)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(normalize_attrs(attrs), [:evidence_subpaths], empty_values: [])
    |> validate_required([:evidence_subpaths])
    |> validate_length(:evidence_subpaths, min: 1)
  end

  defp normalize_attrs(%{} = attrs) do
    cond do
      Map.has_key?(attrs, "evidence_subpaths") ->
        attrs

      Map.has_key?(attrs, "evidence_subpath") ->
        attrs
        |> Map.put("evidence_subpaths", coerce_subpaths(Map.get(attrs, "evidence_subpath")))
        |> Map.delete("evidence_subpath")

      true ->
        attrs
    end
  end

  defp coerce_subpaths(value) when is_binary(value), do: [value]
  defp coerce_subpaths(value) when is_list(value), do: value
  defp coerce_subpaths(_value), do: nil
end
