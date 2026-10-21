# Null means unknown, never zero: rows written before this column existed stay null (no backfill).
class AddCostUsdToApiUsages < ActiveRecord::Migration[8.1]
  def change
    add_column :api_usages, :cost_usd, :decimal, precision: 14, scale: 8
  end
end
