# frozen_string_literal: true

# Memory benchmarking helper for acro_that
# Uses GC.stat and ObjectSpace.memsize_of for memory measurements
module MemoryBenchmarkHelper
  # Measure memory before and after a block
  def self.measure_memory
    # Force GC before measuring
    GC.start
    GC.stat

    before_stats = GC.stat.dup
    before_heap = before_stats[:heap_live_slots] || before_stats[:heap_live] || 0
    before_size = before_stats[:heap_allocated_pages] || before_stats[:heap_allocated] || 0

    # Get RSS if available (process memory)
    rss_before = get_rss_mb

    yield

    # Force GC after operation
    GC.start

    after_stats = GC.stat.dup
    after_heap = after_stats[:heap_live_slots] || after_stats[:heap_live] || 0
    after_size = after_stats[:heap_allocated_pages] || after_stats[:heap_allocated] || 0

    rss_after = get_rss_mb

    {
      heap_live_slots_before: before_heap,
      heap_live_slots_after: after_heap,
      heap_live_slots_delta: after_heap - before_heap,
      heap_allocated_pages_before: before_size,
      heap_allocated_pages_after: after_size,
      heap_allocated_pages_delta: after_size - before_size,
      rss_mb_before: rss_before,
      rss_mb_after: rss_after,
      rss_mb_delta: rss_after - rss_before,
      gc_count_before: before_stats[:count] || 0,
      gc_count_after: after_stats[:count] || 0,
      gc_count_delta: (after_stats[:count] || 0) - (before_stats[:count] || 0)
    }
  end

  # Measure memory for a specific object
  def self.measure_object(obj)
    GC.start
    begin
      ObjectSpace.memsize_of(obj)
    rescue
      0
    end
  end

  # Get process RSS (Resident Set Size) in MB
  def self.get_rss_mb
    # Try to read /proc/self/status (Linux)
    if File.exist?("/proc/self/status")
      status = File.read("/proc/self/status")
      if status =~ /VmRSS:\s+(\d+)\s+kB/
        return ::Regexp.last_match(1).to_i / 1024.0
      end
    end

    # Try ps command (Unix-like)
    begin
      pid = Process.pid
      result = `ps -o rss= -p #{pid} 2>/dev/null`.strip
      return result.to_i / 1024.0 if result =~ /^\d+$/
    rescue
      # Fall through
    end

    # Fallback: estimate from heap
    stats = GC.stat
    heap_size = stats[:heap_allocated_pages] || stats[:heap_allocated] || 0
    heap_live = stats[:heap_live_slots] || stats[:heap_live] || 0

    # Rough estimate: each page is typically 16KB, each slot is ~40 bytes
    (heap_size * 16.0 / 1024.0) + (heap_live * 40.0 / 1024.0 / 1024.0)
  end

  # Measure peak memory during operation
  def self.measure_peak_memory(samples_per_second: 10)
    GC.start

    before_rss = get_rss_mb
    peak_rss = before_rss
    samples = [before_rss]

    start_time = Time.now

    thread = Thread.new do
      loop do
        sleep(1.0 / samples_per_second)
        current_rss = get_rss_mb
        samples << current_rss
        peak_rss = current_rss if current_rss > peak_rss
      end
    end

    yield

    thread.kill
    thread.join

    after_rss = get_rss_mb
    peak_rss = after_rss if after_rss > peak_rss

    {
      rss_mb_before: before_rss,
      rss_mb_after: after_rss,
      rss_mb_peak: peak_rss,
      rss_mb_delta: after_rss - before_rss,
      rss_mb_peak_delta: peak_rss - before_rss,
      samples: samples,
      duration: Time.now - start_time
    }
  end

  # Format memory results for display
  def self.format_results(results)
    output = []

    if results[:rss_mb_delta]
      output << "RSS Memory: #{results[:rss_mb_before].round(2)} MB → #{results[:rss_mb_after].round(2)} MB (Δ #{results[:rss_mb_delta].round(2)} MB)"
      if results[:rss_mb_peak_delta]
        output << "Peak RSS: #{results[:rss_mb_peak].round(2)} MB (Δ #{results[:rss_mb_peak_delta].round(2)} MB from baseline)"
      end
    end

    if results[:heap_live_slots_delta]
      output << "Heap Live Slots: #{results[:heap_live_slots_before]} → #{results[:heap_live_slots_after]} (Δ #{results[:heap_live_slots_delta]})"
    end

    if results[:heap_allocated_pages_delta]
      output << "Heap Pages: #{results[:heap_allocated_pages_before]} → #{results[:heap_allocated_pages_after]} (Δ #{results[:heap_allocated_pages_delta]})"
    end

    if results[:gc_count_delta]
      output << "GC Runs: #{results[:gc_count_delta]}"
    end

    output.join("\n")
  end
end
