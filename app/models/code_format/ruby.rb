# RuboCop's Layout cops only, which move whitespace and nothing else, so a
# planted defect survives formatting token for token. RuboCop's own defaults
# rather than the repository's .rubocop.yml, whose omakase gem is a
# development dependency. Two cops are left out. Layout/LineLength would split
# long lines, a choice about the code rather than its indentation, and
# Layout/HashAlignment would undo a hash lined up as a table, which
# CodeHighlight already keeps readable on a narrow screen.
module CodeFormat
  module Ruby
    EXCLUDED_COPS = %w[Layout/LineLength Layout/HashAlignment].freeze

    # RuboCop keeps configuration and registry state in globals, and the judge
    # fans retries out across threads, so one snippet is formatted at a time.
    LOCK = Mutex.new

    # The formatted code for each snippet, or nil where it does not parse.
    def self.all(snippets)
      require "rubocop"
      LOCK.synchronize { snippets.map { |code| format(code) } }
    end

    def self.format(code)
      # RuboCop qualifies the cop names in place, so it gets its own arrays.
      options = { stdin: code.dup, autocorrect: true, safe_autocorrect: true, only: [ "Layout" ],
                  except: EXCLUDED_COPS.dup, formatters: [ [ "quiet", File::NULL ] ] }
      return unless RuboCop::ProcessedSource.new(code, RUBY_VERSION.to_f, "snippet.rb").valid_syntax?

      RuboCop::Runner.new(options, config_store).run([ "snippet.rb" ])
      options[:stdin]
    end
    private_class_method :format

    def self.config_store
      RuboCop::ConfigStore.new.tap do |store|
        store.options_config = File.join(RuboCop::ConfigLoader::RUBOCOP_HOME, "config", "default.yml")
      end
    end
    private_class_method :config_store
  end
end
