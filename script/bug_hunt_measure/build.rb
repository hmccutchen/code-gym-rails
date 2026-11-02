# Design notes: docs/code-notes/script/bug_hunt_measure.md
require "json"
require "securerandom"
require "digest"
require "zlib"
require "rubygems/package"

module BugHuntMeasure
  TEMPLATES = Pathname(__dir__).join("templates")

  RUNTIME_FOR = { "ruby_rails" => "ruby", "javascript" => "node" }.freeze

  PREFIX_FOR = { "ruby_rails" => "rb", "javascript" => "js" }.freeze

  RAISES = /\Araises ([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)\z/

  CHECKS = {
    "bug_real"        => { code: "snippet",       spec: %w[witness expected],        call: "witness" },
    "returns_match"   => { code: "snippet",       spec: %w[witness returns],         call: "witness" },
    "looks_right"     => { code: "snippet",       spec: %w[looks_right_on expected], call: "looks_right_on" },
    "fix_witness"     => { code: "fixed_snippet", spec: %w[witness expected],        call: "witness" },
    "fix_looks_right" => { code: "fixed_snippet", spec: %w[looks_right_on expected], call: "looks_right_on" }
  }.freeze

  LOOKS_RIGHT_CHECKS = %w[looks_right fix_looks_right].freeze

  def self.outside_repository!(path)
    full = File.expand_path(path)
    parent = File.realpath(File.dirname(full))
    resolved = File.join(parent, File.basename(full))
    raise ArgumentError, "Write it outside the repository: #{resolved}" if "#{resolved}/".start_with?("#{Rails.root.realpath}/")

    resolved
  rescue Errno::ENOENT
    raise ArgumentError, "No directory for #{path}"
  end

  class Build
    Harness = Data.define(:id, :draft, :check, :runtime, :files)

    def initialize(drafts_paths, harness_dir)
      @sections = Array(drafts_paths).flat_map { |path| JSON.parse(File.read(path)).fetch("sections") }
      @dir      = BugHuntMeasure.outside_repository!(harness_dir)
      @archive  = "#{@dir}.tar.gz"
      raise ArgumentError, "#{@dir} already exists" if File.exist?(@dir)
      raise ArgumentError, "#{@archive} already exists" if File.exist?(@archive)
    end

    def call
      drafts    = @sections.map { |section| draft(section) }
      harnesses = drafts.flat_map { |draft| harnesses_for(draft) }
      raise ArgumentError, "Two drafts share a registry entry" if drafts.map { |draft| draft["draft"] }.uniq.size != drafts.size

      write_folder(drafts, harnesses)
      write_archive
      { dir: @dir, archive: @archive, sha256: Digest::SHA256.file(@archive).hexdigest, drafts: drafts.size, harnesses: harnesses.size }
    end

    private

    def draft(section)
      language = section.fetch("language")
      registry = BugHuntGotchas.for_language(language)
      index    = registry.index { |gotcha| gotcha.id == section.fetch("registry_id") } or
        raise ArgumentError, "#{section["registry_id"]} isn't in the #{language} registry"
      snippet  = section.dig("shown", "snippet").to_s

      { "draft" => format("%s%02d", PREFIX_FOR.fetch(language), index + 1), "registry_id" => section["registry_id"],
        "language" => language, "rung" => section["rung"], "concept" => section["concept"], "purpose" => section["purpose"],
        "snippet" => snippet, "answer_key" => section["answer_key"] || {},
        "lines" => snippet.lines.count { |line| line.strip.present? },
        "longest_line" => snippet.lines.map { |line| line.chomp.length }.max.to_i }
    end

    def harnesses_for(draft)
      key = draft["answer_key"]
      CHECKS.filter_map do |check, parts|
        next if LOOKS_RIGHT_CHECKS.include?(check) && !key["looks_right_on"].is_a?(Hash)

        Harness.new(id: "#{draft["draft"]}-#{check}", draft: draft["draft"], check: check,
                    runtime: RUNTIME_FOR.fetch(draft["language"]), files: files_for(draft, key, check, parts))
      end
    end

    def files_for(draft, key, check, parts)
      code    = parts[:code] == "snippet" ? draft["snippet"] : key["fixed_snippet"]
      call    = key.dig(parts[:call], "call")
      text    = key.dig(*parts[:spec])
      raises  = text.to_s.strip[RAISES, 1]
      usable  = [ code, call, text ].all? { |value| value.is_a?(String) && value.strip.present? }
      runtime = RUNTIME_FOR.fetch(draft["language"])
      id      = "#{draft["draft"]}-#{check}"

      files = { runner(runtime, id) => runner_text(runtime, id, check, usable ? raises : :unusable),
                subject(runtime, id) => subject_text(runtime, usable ? code : nil, call) }
      usable && raises.nil? ? files.merge(literal(runtime, id) => literal_text(runtime, text)) : files
    end

    def runner(runtime, id) = runtime == "ruby" ? "#{id}.rb" : "#{id}.mjs"

    def subject(runtime, id) = runtime == "ruby" ? "#{id}.subject.rb" : "#{id}.subject.mjs"

    def literal(runtime, id) = runtime == "ruby" ? "#{id}.expected.rb" : "#{id}.expected.mjs"

    def runner_text(runtime, id, check, raises)
      template = TEMPLATES.join(runtime == "ruby" ? "runner.rb.template" : "runner.mjs.template").read
      template.sub("%HARNESS%", id).sub("%CHECK%", check).sub("%SPEC%", spec_text(runtime, raises))
    end

    def spec_text(runtime, raises)
      return (runtime == "ruby" ? "nil" : "null") if raises == :unusable
      return (runtime == "ruby" ? '{ "raises" => nil }' : "{ raises: null }") if raises.nil?

      runtime == "ruby" ? %({ "raises" => "#{raises}" }) : %({ raises: "#{raises}" })
    end

    def subject_text(runtime, code, call)
      return (runtime == "ruby" ? "nil\n" : "export const __bughuntResult = null;\n") if code.nil?

      runtime == "ruby" ? "#{code}\n#{call}\n" : "#{code}\nexport const __bughuntResult = await (async () => (#{call}))();\n"
    end

    def literal_text(runtime, text) = runtime == "ruby" ? "#{text}\n" : "export default (#{text});\n"

    def write_folder(drafts, harnesses)
      FileUtils.mkdir_p(@dir)
      build_id = SecureRandom.hex(6)
      harnesses.each { |harness| harness.files.each { |name, text| File.write(File.join(@dir, name), text) } }
      File.write(File.join(@dir, "harnesses.txt"), harnesses.map { |harness| "#{harness.id} #{harness.runtime} #{harness.files.keys.first}\n" }.join)
      File.write(File.join(@dir, "build_id"), "#{build_id}\n")
      File.write(File.join(@dir, "run.sh"), TEMPLATES.join("run.sh.template").read)
      File.chmod(0o755, File.join(@dir, "run.sh"))
      manifest = { "build_id" => build_id, "drafts" => drafts,
                   "harnesses" => harnesses.map { |harness| { "harness" => harness.id, "draft" => harness.draft, "check" => harness.check,
                                                               "runtime" => harness.runtime } } }
      File.write(File.join(@dir, "manifest.json"), JSON.pretty_generate(manifest))
    end

    def write_archive
      names = Dir.children(@dir).sort - [ "manifest.json" ]
      File.open(@archive, "wb") do |file|
        Zlib::GzipWriter.wrap(file) do |gzip|
          Gem::Package::TarWriter.new(gzip) do |tar|
            names.each do |name|
              body = File.binread(File.join(@dir, name))
              tar.add_file_simple(name, name == "run.sh" ? 0o755 : 0o644, body.bytesize) { |io| io.write(body) }
            end
          end
        end
      end
    end
  end
end
