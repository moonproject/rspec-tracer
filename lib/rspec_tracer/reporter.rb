# frozen_string_literal: true

require 'msgpack'

module RSpecTracer
  class Reporter
    attr_reader :all_examples, :interrupted_examples, :duplicate_examples,
                :possibly_flaky_examples, :flaky_examples, :pending_examples,
                :all_files, :modified_files, :deleted_files, :dependency,
                :reverse_dependency, :examples_coverage, :last_run

    def initialize
      initialize_examples
      initialize_files
      initialize_dependency
      initialize_coverage
    end

    def register_example(example)
      @all_examples[example[:example_id]] = example
      @duplicate_examples[example[:example_id]] << example
    end

    def deregister_duplicate_examples
      @duplicate_examples.select! { |_, examples| examples.count > 1 }

      return if @duplicate_examples.empty?

      @all_examples.reject! { |example_id, _| @duplicate_examples.key?(example_id) }
    end

    def on_example_skipped(example_id)
      @skipped_examples << example_id
    end

    def on_example_passed(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @passed_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def on_example_failed(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @failed_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def on_example_pending(example_id, result)
      return if @duplicate_examples.key?(example_id)

      @pending_examples << example_id
      @all_examples[example_id][:execution_result] = formatted_execution_result(result)
    end

    def register_interrupted_examples
      @all_examples.each_pair do |example_id, example|
        next if example.key?(:execution_result)

        @interrupted_examples << example_id
      end

      return if @interrupted_examples.empty?

      puts "RSpec tracer is not processing #{@interrupted_examples.count} interrupted examples"
    end

    def register_deleted_examples(seen_examples)
      @deleted_examples = seen_examples.keys.to_set - (@skipped_examples | @all_examples.keys)
      @deleted_examples -= @interrupted_examples

      @deleted_examples.select! do |example_id|
        example = seen_examples[example_id]

        file_changed?(example[:file_name]) || file_changed?(example[:rerun_file_name])
      end
    end

    def register_possibly_flaky_example(example_id)
      @possibly_flaky_examples << example_id
    end

    def register_flaky_example(example_id)
      @flaky_examples << example_id
    end

    def register_failed_example(example_id)
      @failed_examples << example_id
    end

    def register_pending_example(example_id)
      @pending_examples << example_id
    end

    def duplicate_example?(example_id)
      @duplicate_examples.key?(example_id)
    end

    def example_interrupted?(example_id)
      @interrupted_examples.include?(example_id)
    end

    def example_passed?(example_id)
      @passed_examples.include?(example_id)
    end

    def example_skipped?(example_id)
      @skipped_examples.include?(example_id)
    end

    def example_failed?(example_id)
      @failed_examples.include?(example_id)
    end

    def example_pending?(example_id)
      @pending_examples.include?(example_id)
    end

    def example_deleted?(example_id)
      @deleted_examples.include?(example_id)
    end

    def register_source_file(source_file)
      @all_files[source_file[:file_name]] = source_file
    end

    def on_file_deleted(file_name)
      @deleted_files << file_name
    end

    def on_file_modified(file_name)
      @modified_files << file_name
    end

    def file_deleted?(file_name)
      @deleted_files.include?(file_name)
    end

    def file_modified?(file_name)
      @modified_files.include?(file_name)
    end

    def file_changed?(file_name)
      file_deleted?(file_name) || file_modified?(file_name)
    end

    def register_dependency(example_id, file_name)
      @dependency[example_id] << file_name
    end

    def register_examples_coverage(examples_coverage)
      @examples_coverage = examples_coverage
    end

    def generate_reverse_dependency_report
      @dependency.each_pair do |example_id, files|
        next if @interrupted_examples.include?(example_id)

        example_file = @all_examples[example_id][:rerun_file_name]

        files.each do |file_name|
          @reverse_dependency[file_name][:example_count] += 1
          @reverse_dependency[file_name][:examples][example_file] += 1
        end
      end

      format_reverse_dependency_report
    end

    def generate_last_run_report
      @last_run = {
        pid: RSpecTracer.pid,
        actual_count: RSpec.world.example_count + @skipped_examples.count,
        example_count: RSpec.world.example_count,
        duplicate_examples: @duplicate_examples.sum { |_, examples| examples.count },
        interrupted_examples: @interrupted_examples.count,
        failed_examples: @failed_examples.count,
        skipped_examples: @skipped_examples.count,
        pending_examples: @pending_examples.count,
        flaky_examples: @flaky_examples.count
      }
    end

    def write_reports
      starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @run_id = Digest::MD5.hexdigest(@all_examples.keys.sort.to_json)
      @cache_dir = File.join(RSpecTracer.cache_path, @run_id)

      FileUtils.mkdir_p(@cache_dir)

      %i[
        all_examples
        flaky_examples
        failed_examples
        pending_examples
        all_files
        dependency
        reverse_dependency
        examples_coverage
        last_run
      ].each { |report_type| send("write_#{report_type}_report") }

      ending = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elpased = RSpecTracer::TimeFormatter.format_time(ending - starting)

      puts "RSpec tracer reports written to #{@cache_dir} (took #{elpased})"
    end

    # rubocop:disable Metrics/AbcSize
    def print_duplicate_examples
      return if @duplicate_examples.empty?

      total = @duplicate_examples.sum { |_, examples| examples.count }

      puts '=' * 80
      puts '   IMPORTANT NOTICE -- RSPEC TRACER COULD NOT IDENTIFY SOME EXAMPLES UNIQUELY'
      puts '=' * 80
      puts "RSpec tracer could not uniquely identify the following #{total} examples:"

      justify = ' ' * 2
      nested_justify = justify * 3

      @duplicate_examples.each_pair do |example_id, examples|
        puts "#{justify}- Example ID: #{example_id} (#{examples.count} examples)"

        examples.each do |example|
          description = example[:full_description].strip
          file_name = example[:rerun_file_name].sub(%r{^/}, '')
          line_number = example[:rerun_line_number]
          location = "#{file_name}:#{line_number}"

          puts "#{nested_justify}* #{description} (#{location})"
        end
      end

      puts
    end
    # rubocop:enable Metrics/AbcSize

    private

    def initialize_examples
      @all_examples = {}
      @duplicate_examples = Hash.new { |examples, example_id| examples[example_id] = [] }
      @interrupted_examples = Set.new
      @passed_examples = Set.new
      @possibly_flaky_examples = Set.new
      @flaky_examples = Set.new
      @failed_examples = Set.new
      @skipped_examples = Set.new
      @pending_examples = Set.new
      @deleted_examples = Set.new
    end

    def initialize_files
      @all_files = {}
      @modified_files = Set.new
      @deleted_files = Set.new
    end

    def initialize_dependency
      @dependency = Hash.new { |hash, key| hash[key] = Set.new }
      @reverse_dependency = Hash.new do |examples, file_name|
        examples[file_name] = {
          example_count: 0,
          examples: Hash.new(0)
        }
      end
    end

    def initialize_coverage
      @examples_coverage = Hash.new do |examples, example_id|
        examples[example_id] = Hash.new do |files, file_name|
          files[file_name] = {}
        end
      end
    end

    def formatted_execution_result(result)
      {
        started_at: result.started_at.utc,
        finished_at: result.finished_at.utc,
        run_time: result.run_time,
        status: result.status.to_s
      }
    end

    def format_reverse_dependency_report
      @reverse_dependency.transform_values! do |data|
        {
          example_count: data[:example_count],
          examples: data[:examples].sort_by { |file_name, count| [-count, file_name] }.to_h
        }
      end

      report = @reverse_dependency.sort_by do |file_name, data|
        [-data[:example_count], file_name]
      end

      @reverse_dependency = report.to_h
    end

    def write_all_examples_report
      file_name = File.join(@cache_dir, "all_examples.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@all_examples),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_flaky_examples_report
      file_name = File.join(@cache_dir, "flaky_examples.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@flaky_examples.to_a),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_failed_examples_report
      file_name = File.join(@cache_dir, "failed_examples.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@failed_examples.to_a),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_pending_examples_report
      file_name = File.join(@cache_dir, "pending_examples.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@pending_examples.to_a),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_all_files_report
      file_name = File.join(@cache_dir, "all_files.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@all_files),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_dependency_report
      file_name = File.join(@cache_dir, "dependency.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@dependency),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_reverse_dependency_report
      file_name = File.join(@cache_dir, "reverse_dependency.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@reverse_dependency),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_examples_coverage_report
      file_name = File.join(@cache_dir, "examples_coverage.#{RSpecTracer.cache_serializer::EXTENSION}")

      File.write(file_name, RSpecTracer.cache_serializer.serialize(@examples_coverage),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end

    def write_last_run_report
      file_name = File.join(RSpecTracer.cache_path, "last_run.#{RSpecTracer.cache_serializer::EXTENSION}")
      last_run_data = @last_run.merge(run_id: @run_id, timestamp: Time.now.utc)

      File.write(file_name, RSpecTracer.cache_serializer.serialize(last_run_data),
                 encoding: RSpecTracer.cache_serializer::ENCODING)
    end
  end
end
