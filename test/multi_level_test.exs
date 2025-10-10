defmodule CrucibleHedging.MultiLevelTest do
  use ExUnit.Case

  describe "execute/2" do
    test "returns first tier result when fast" do
      tiers = [
        %{
          name: :tier1,
          delay_ms: 500,
          request_fn: fn ->
            Process.sleep(10)
            :tier1_result
          end
        },
        %{
          name: :tier2,
          delay_ms: 0,
          request_fn: fn ->
            :tier2_result
          end
        }
      ]

      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      assert result == :tier1_result
      assert metadata.tier == :tier1
      assert metadata.hedges_fired == 0
    end

    test "escalates to second tier when first is slow" do
      tiers = [
        %{
          name: :tier1,
          delay_ms: 50,
          request_fn: fn ->
            Process.sleep(500)
            :tier1_result
          end
        },
        %{
          name: :tier2,
          delay_ms: 0,
          request_fn: fn ->
            Process.sleep(10)
            :tier2_result
          end
        }
      ]

      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      assert result in [:tier1_result, :tier2_result]
      assert metadata.hedges_fired >= 1
    end

    test "respects quality thresholds" do
      tiers = [
        %{
          name: :tier1,
          delay_ms: 50,
          quality_threshold: 0.95,
          request_fn: fn ->
            Process.sleep(10)
            %{result: :low_quality, confidence: 0.8}
          end
        },
        %{
          name: :tier2,
          delay_ms: 0,
          quality_threshold: 0.0,
          request_fn: fn ->
            Process.sleep(10)
            %{result: :acceptable, confidence: 0.7}
          end
        }
      ]

      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      # Should use tier2 because tier1 doesn't meet quality threshold
      assert result.result == :acceptable
      assert metadata.tier == :tier2
    end

    test "tracks cost across tiers" do
      tiers = [
        %{
          name: :expensive,
          delay_ms: 50,
          cost: 0.03,
          request_fn: fn ->
            Process.sleep(200)
            :expensive_result
          end
        },
        %{
          name: :cheap,
          delay_ms: 0,
          cost: 0.001,
          request_fn: fn ->
            Process.sleep(10)
            :cheap_result
          end
        }
      ]

      {:ok, _result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      assert is_float(metadata.total_cost)
      assert metadata.total_cost > 0
    end

    test "handles tier failures gracefully" do
      tiers = [
        %{
          name: :failing_tier,
          delay_ms: 50,
          request_fn: fn ->
            raise "Tier failed"
          end
        },
        %{
          name: :backup_tier,
          delay_ms: 0,
          request_fn: fn ->
            :backup_result
          end
        }
      ]

      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      assert result == :backup_result
      assert metadata.tier == :backup_tier
    end
  end
end
