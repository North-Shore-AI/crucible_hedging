defmodule CrucibleHedging.ConformanceTest do
  @moduledoc """
  Conformance tests for the CrucibleHedging.CrucibleStage describe/1 contract.

  These tests verify that the stage implements the canonical schema format
  as defined in the Stage Describe Contract specification v1.0.0.
  """
  use ExUnit.Case, async: true

  alias CrucibleHedging.CrucibleStage

  describe "stage conformance" do
    test "implements Crucible.Stage behaviour" do
      assert function_exported?(CrucibleStage, :run, 2)
      assert function_exported?(CrucibleStage, :describe, 1)
    end

    test "describe/1 returns valid canonical schema" do
      schema = CrucibleStage.describe(%{})

      # Must use :name key, not :stage
      assert Map.has_key?(schema, :name)
      refute Map.has_key?(schema, :stage)

      # Name must be atom
      assert schema.name == :hedging
      assert is_atom(schema.name)

      # Required core fields
      assert is_list(schema.required)
      assert is_list(schema.optional)
      assert is_map(schema.types)

      # Required fields have types
      for key <- schema.required do
        assert Map.has_key?(schema.types, key),
               "Required field #{key} missing from types"
      end
    end

    test "has request_fn as required" do
      schema = CrucibleStage.describe(%{})
      assert :request_fn in schema.required
    end

    test "has schema version marker" do
      schema = CrucibleStage.describe(%{})
      assert Map.has_key?(schema, :__schema_version__)
      assert schema.__schema_version__ == "1.0.0"
    end

    test "has description as non-empty string" do
      schema = CrucibleStage.describe(%{})
      assert Map.has_key?(schema, :description)
      assert is_binary(schema.description)
      assert String.length(schema.description) > 0
    end

    test "optional fields have types" do
      schema = CrucibleStage.describe(%{})

      for key <- schema.optional do
        assert Map.has_key?(schema.types, key),
               "Optional field #{key} missing from types"
      end
    end

    test "defaults keys are subset of optional" do
      schema = CrucibleStage.describe(%{})

      if Map.has_key?(schema, :defaults) do
        for key <- Map.keys(schema.defaults) do
          assert key in schema.optional,
                 "Default key #{key} not in optional list"
        end
      end
    end

    test "required and optional are mutually exclusive" do
      schema = CrucibleStage.describe(%{})

      intersection =
        MapSet.intersection(
          MapSet.new(schema.required),
          MapSet.new(schema.optional)
        )

      assert MapSet.size(intersection) == 0,
             "Fields cannot be both required and optional: #{inspect(MapSet.to_list(intersection))}"
    end

    test "extensions are stored in __extensions__" do
      schema = CrucibleStage.describe(%{})
      assert Map.has_key?(schema, :__extensions__)
      assert is_map(schema.__extensions__)
    end

    test "hedging extension includes inputs and outputs" do
      schema = CrucibleStage.describe(%{})

      assert Map.has_key?(schema.__extensions__, :hedging)
      hedging_ext = schema.__extensions__.hedging

      assert Map.has_key?(hedging_ext, :inputs)
      assert Map.has_key?(hedging_ext, :outputs)
      assert is_list(hedging_ext.inputs)
      assert is_list(hedging_ext.outputs)
    end

    test "hedging extension includes config_type" do
      schema = CrucibleStage.describe(%{})

      hedging_ext = schema.__extensions__.hedging
      assert Map.has_key?(hedging_ext, :config_type)
      assert hedging_ext.config_type == CrucibleIR.Reliability.Hedging
    end
  end

  describe "type specifications" do
    test "request_fn has function type with arity 0" do
      schema = CrucibleStage.describe(%{})
      assert schema.types.request_fn == {:function, 0}
    end

    test "strategy has enum type with valid strategies" do
      schema = CrucibleStage.describe(%{})
      {:enum, strategies} = schema.types.strategy

      assert :off in strategies
      assert :fixed in strategies
      assert :percentile in strategies
      assert :adaptive in strategies
      assert :workload_aware in strategies
      assert :exponential_backoff in strategies
    end

    test "numeric fields have correct types" do
      schema = CrucibleStage.describe(%{})

      assert schema.types.delay_ms == :integer
      assert schema.types.percentile == :float
      assert schema.types.max_hedges == :integer
      assert schema.types.timeout_ms == :integer
    end
  end

  describe "default values" do
    test "has reasonable defaults" do
      schema = CrucibleStage.describe(%{})

      assert schema.defaults.strategy == :off
      assert schema.defaults.delay_ms == 100
      assert schema.defaults.max_hedges == 2
      assert schema.defaults.timeout_ms == 30_000
    end
  end
end
