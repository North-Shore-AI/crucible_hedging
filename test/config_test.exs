defmodule CrucibleHedging.ConfigTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  doctest CrucibleHedging.Config

  describe "validate/1" do
    test "returns error for invalid strategy" do
      assert {:error, _error} = CrucibleHedging.Config.validate(strategy: :invalid)
    end

    test "requires delay_ms for fixed strategy" do
      assert {:error, _error} = CrucibleHedging.Config.validate(strategy: :fixed)
    end

    test "accepts valid fixed strategy config" do
      assert {:ok, config} =
               CrucibleHedging.Config.validate(strategy: :fixed, delay_ms: 100)

      assert config[:strategy] == :fixed
      assert config[:delay_ms] == 100
    end

    test "validates percentile range" do
      assert {:error, _error} =
               CrucibleHedging.Config.validate(strategy: :percentile, percentile: 100)

      assert {:error, _error} =
               CrucibleHedging.Config.validate(strategy: :percentile, percentile: 40)

      assert {:ok, config} =
               CrucibleHedging.Config.validate(strategy: :percentile, percentile: 95)

      assert config[:percentile] == 95
    end

    test "validates adaptive strategy has enough candidates" do
      assert {:error, _error} =
               CrucibleHedging.Config.validate(strategy: :adaptive, delay_candidates: [100])

      assert {:ok, config} =
               CrucibleHedging.Config.validate(strategy: :adaptive, delay_candidates: [50, 100])

      assert config[:delay_candidates] == [50, 100]
    end
  end

  describe "validate!/1" do
    test "raises for invalid config" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(strategy: :fixed)
      end
    end

    test "returns config for valid input" do
      config = CrucibleHedging.Config.validate!(strategy: :fixed, delay_ms: 200)
      assert config[:strategy] == :fixed
      assert config[:delay_ms] == 200
    end
  end

  describe "with_defaults/1" do
    test "merges user options with defaults" do
      opts = CrucibleHedging.Config.with_defaults(strategy: :fixed, delay_ms: 200)

      assert opts[:strategy] == :fixed
      assert opts[:delay_ms] == 200
      assert opts[:percentile] == 95
      assert opts[:timeout_ms] == 30_000
    end

    test "uses defaults when no options provided" do
      opts = CrucibleHedging.Config.with_defaults([])

      assert opts[:strategy] == :percentile
      assert opts[:percentile] == 95
      assert opts[:timeout_ms] == 30_000
    end
  end
end
