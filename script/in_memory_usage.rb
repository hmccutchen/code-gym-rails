# Reasoning: docs/code-notes/script/in_memory_usage.md
module InMemoryUsage
  def self.provider(base, usage, &row)
    lock = Mutex.new

    Class.new(base) do
      define_method(:log_usage) do |_user, result, purpose:|
        entry = row ? instance_exec(result, purpose, &row) : InMemoryUsage.tokens(result)
        lock.synchronize { usage << entry }
      end
      define_method(:record_suggested_concept) { |_suggestion| }
      private :log_usage, :record_suggested_concept
    end
  end

  def self.tokens(result) = { tokens_in: result[:input_tokens].to_i, tokens_out: result[:output_tokens].to_i }
end
