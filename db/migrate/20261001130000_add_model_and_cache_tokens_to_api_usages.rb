# Nullable, no default: null means unknown on older rows, where zero would read as an uncached call.
class AddModelAndCacheTokensToApiUsages < ActiveRecord::Migration[8.1]
  def change
    add_column :api_usages, :model, :string
    add_column :api_usages, :cache_read_tokens, :integer
    add_column :api_usages, :cache_write_tokens, :integer
  end
end
