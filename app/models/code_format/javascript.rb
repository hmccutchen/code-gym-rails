require "open3"

# Prettier, run once per batch in a Node process from vendor/prettier, so a
# whole set pays one process start rather than one per snippet.
module CodeFormat
  module Javascript
    SCRIPT = Rails.root.join("vendor/prettier/format.mjs").to_s
    TIMEOUT_SECONDS = 20

    # The formatted code for each snippet, or nil where Prettier could not
    # parse it. Raises when Node or the package is missing; CodeFormat.all
    # treats that like any other formatter failure.
    def self.all(snippets)
      output = run(JSON.generate(snippets))
      formatted = JSON.parse(output)
      raise ArgumentError, "Prettier returned #{formatted.size} results for #{snippets.size} snippets" unless formatted.size == snippets.size

      formatted
    end

    def self.run(input)
      Open3.popen3("node", SCRIPT) do |stdin, stdout, stderr, wait|
        stdin.write(input)
        stdin.close
        reader = Thread.new { stdout.read }
        Thread.new { stderr.read }
        unless wait.join(TIMEOUT_SECONDS)
          Process.kill("KILL", wait.pid)
          raise Timeout::Error, "Prettier took longer than #{TIMEOUT_SECONDS} seconds"
        end
        raise IOError, "Prettier exited with #{wait.value.exitstatus}" unless wait.value.success?

        reader.value
      end
    end
    private_class_method :run
  end
end
