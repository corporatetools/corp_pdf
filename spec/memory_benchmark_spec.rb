# frozen_string_literal: true

require "spec_helper"
require "memory_benchmark_helper"

RSpec.describe "Memory Benchmarks", type: :benchmark do
  let(:pdf_path) { File.join(__dir__, "fixtures", "form.pdf") }

  describe "Document initialization memory usage" do
    it "measures memory for document creation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      results = MemoryBenchmarkHelper.measure_memory do
        doc = AcroThat::Document.new(pdf_path)
        expect(doc).to be_a(AcroThat::Document)
      end

      puts "\n=== Document Initialization ==="
      puts MemoryBenchmarkHelper.format_results(results)

      # Store results for comparison
      @init_results = results
    end

    it "measures memory sharing between @raw and ObjectResolver#{@bytes}" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      raw_size = MemoryBenchmarkHelper.measure_object(doc.instance_variable_get(:@raw))
      resolver_bytes = doc.instance_variable_get(:@resolver).instance_variable_get(:@bytes)
      bytes_size = MemoryBenchmarkHelper.measure_object(resolver_bytes)

      puts "\n=== Memory Sharing Check ==="
      puts "@raw size: #{raw_size} bytes"
      puts "ObjectResolver#{@bytes} size: #{bytes_size} bytes"
      puts "Total if separate: #{raw_size + bytes_size} bytes"

      # Check if they share memory (same object reference)
      raw_ref = doc.instance_variable_get(:@raw)
      resolver_ref = doc.instance_variable_get(:@resolver).instance_variable_get(:@bytes)
      same_reference = raw_ref.equal?(resolver_ref)

      puts "Same object reference: #{same_reference}"
      puts "Object IDs: #{raw_ref.object_id} vs #{resolver_ref.object_id}"

      @memory_sharing = {
        raw_size: raw_size,
        bytes_size: bytes_size,
        same_reference: same_reference
      }
    end
  end

  describe "list_fields memory usage" do
    it "measures memory for list_fields operation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      results = MemoryBenchmarkHelper.measure_memory do
        fields = doc.list_fields
        expect(fields).to be_an(Array)
        # NOTE: form.pdf may not have form fields
      end

      puts "\n=== list_fields Operation ==="
      puts MemoryBenchmarkHelper.format_results(results)

      @list_fields_results = results
    end
  end

  describe "flatten memory usage" do
    it "measures memory for flatten operation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      results = MemoryBenchmarkHelper.measure_memory do
        flattened = doc.flatten
        expect(flattened).to be_a(String)
        expect(flattened.length).to be > 0
      end

      puts "\n=== flatten Operation ==="
      puts MemoryBenchmarkHelper.format_results(results)

      @flatten_results = results
    end

    it "measures memory for flatten! operation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      results = MemoryBenchmarkHelper.measure_memory do
        doc.flatten!
        expect(doc.instance_variable_get(:@raw)).to be_a(String)
      end

      puts "\n=== flatten! Operation ==="
      puts MemoryBenchmarkHelper.format_results(results)

      @flatten_bang_results = results
    end
  end

  describe "write memory usage" do
    it "measures memory for write operation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)
      doc.add_field("TestField", value: "Test", x: 100, y: 500, width: 200, height: 20, page: 1)

      results = MemoryBenchmarkHelper.measure_memory do
        output = doc.write
        expect(output).to be_a(String)
      end

      puts "\n=== write Operation ==="
      puts MemoryBenchmarkHelper.format_results(results)

      @write_results = results
    end
  end

  describe "clear memory usage" do
    it "measures memory for clear operation" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      results = MemoryBenchmarkHelper.measure_memory do
        cleared = doc.clear(remove_pattern: /^$/) # Remove nothing
        expect(cleared).to be_a(String)
      end

      puts "\n=== clear Operation ==="
      puts MemoryBenchmarkHelper.format_results(results)

      @clear_results = results
    end
  end

  describe "ObjectResolver cache memory usage" do
    it "measures memory after accessing objects in streams" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)
      resolver = doc.instance_variable_get(:@resolver)

      # Access objects to populate cache
      results = MemoryBenchmarkHelper.measure_memory do
        resolver.each_object do |_ref, body|
          # Access body to potentially load object streams
          body if body
        end
      end

      cache_size = resolver.instance_variable_get(:@objstm_cache).size
      cache_keys = resolver.instance_variable_get(:@objstm_cache).keys

      puts "\n=== ObjectResolver Cache ==="
      puts MemoryBenchmarkHelper.format_results(results)
      puts "Cached object streams: #{cache_size}"
      puts "Cache keys: #{cache_keys.inspect}"

      @cache_results = results
      @cache_size = cache_size
    end
  end

  describe "peak memory during operations" do
    it "measures peak memory during flatten" do
      skip "Benchmark - run with BENCHMARK=true" unless ENV["BENCHMARK"] == "true"

      doc = AcroThat::Document.new(pdf_path)

      results = MemoryBenchmarkHelper.measure_peak_memory do
        flattened = doc.flatten
        expect(flattened).to be_a(String)
      end

      puts "\n=== Peak Memory During flatten ==="
      puts "Peak RSS: #{results[:rss_mb_peak].round(2)} MB"
      puts "Peak Delta: #{results[:rss_mb_peak_delta].round(2)} MB"
      puts "Duration: #{results[:duration].round(2)}s"

      @peak_flatten_results = results
    end
  end
end
