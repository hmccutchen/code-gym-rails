# Nullable with no default on purpose: rows written before these columns
# existed did not record them, and null says unknown where a zero would read
# as an uncached call.
class AddModelAndCacheTokensToApiUsages < ActiveRecord::Migration[8.1]
  def change
    add_column :api_usages, :model, :string
    add_column :api_usages, :cache_read_tokens, :integer
    add_column :api_usages, :cache_write_tokens, :integer
  end
end
