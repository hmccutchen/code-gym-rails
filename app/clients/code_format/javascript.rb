require "open3"

# One Node process per batch, so a whole set pays one process start rather than one per snippet.
module CodeFormat
  module Javascript
    SCRIPT = Rails.root.join("vendor/prettier/format.mjs").to_s
    TIMEOUT_SECONDS = 20
    READER_GRACE_SECONDS = 2

    # nil where Prettier could not parse a snippet; raises when Node or the package is missing.
    def self.all(snippets)
      output = run(JSON.generate(snippets))
      formatted = JSON.parse(output)
      raise ArgumentError, "Prettier returned #{formatted.size} results for #{snippets.size} snippets" unless formatted.size == snippets.size

      formatted
    end

    def self.run(input)
      Open3.popen3("node", SCRIPT) do |stdin, stdout, stderr, wait|
        readers = [ stdout, stderr ].map { |io| Thread.new { io.read } }
        stdin.write(input)
        stdin.close
        finish(wait)
        raise Timeout::Error, "Prettier's output stayed open after it exited" unless settle(readers)

        readers.first.value
      ensure
        settle(readers) if readers
      end
    end
    private_class_method :run

    def self.settle(readers)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READER_GRACE_SECONDS
      finished = readers.map do |reader|
        reader.join([ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max).tap { |done| reader.kill.join unless done }
      end
      finished.all?
    end
    private_class_method :settle

    def self.finish(wait)
      unless wait.join(TIMEOUT_SECONDS)
        Process.kill("KILL", wait.pid)
        raise Timeout::Error, "Prettier took longer than #{TIMEOUT_SECONDS} seconds"
      end
      raise IOError, "Prettier exited with #{wait.value.exitstatus}" unless wait.value.success?
    end
    private_class_method :finish
  end
end
