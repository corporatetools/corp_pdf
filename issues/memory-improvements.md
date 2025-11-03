# Memory Improvement Opportunities

This document identifies memory usage issues and opportunities to optimize memory consumption for handling larger PDF documents.

## Overview

Currently, `acro_that` loads entire PDF files into memory and creates multiple copies during processing. For small to medium PDFs (<20MB), this is acceptable, but for larger documents (39+ pages, especially with images/compressed streams), memory usage can become problematic.

### Current Memory Footprint

For a typical 10MB PDF:
- **Initial load**: ~10MB (Document `@raw`)
- **ObjectResolver**: ~10MB (`@bytes` - separate copy)
- **Decompressed streams**: ~20-50MB (cached in `@objstm_cache`)
- **Operations (flatten/clear)**: ~10-20MB (new PDF buffer)
- **Total peak**: ~50-90MB

For larger PDFs (39+ pages with images), peak memory can easily exceed **100-200MB**.

---

## 1. Duplicate Full PDF in Memory

### Issue
The PDF file is loaded twice: once in `Document#@raw` and again in `ObjectResolver#@bytes`.

### Current Implementation
```ruby
# document.rb line 21-26
@raw = File.binread(path_or_io)  # First copy: ~10MB
@resolver = AcroThat::ObjectResolver.new(@raw)  # Second copy: ~10MB
```

### Suggested Improvement
**Option A: Shared String Buffer**
- Use frozen strings to allow Ruby to share memory
- Or: Pass a reference instead of copying

**Option B: Lazy Loading with File IO**
- Keep file handle open
- Read chunks on demand instead of loading entire file
- Use `IO#seek` and `IO#read` for object access

**Option C: Memory-Mapped Files** (Advanced)
- Use `mmap` to map file to memory without loading
- Read-only access via memory mapping

### Benefits
- **Immediate**: ~50% reduction in base memory (eliminates duplicate)
- **Impact**: High - affects every operation

### Priority
**HIGH** - This is the easiest win with immediate impact.

---

## 2. Stream Decompression Cache Retention

### Issue
Decompressed object streams are cached in `@objstm_cache` and never cleared, even after they're no longer needed.

### Current Implementation
```ruby
# object_resolver.rb line 357-374
def load_objstm(container_ref)
  return if @objstm_cache.key?(container_ref)  # Cached forever
  # ... decompress stream ...
  @objstm_cache[container_ref] = parsed  # Never cleared
end
```

### Suggested Improvement
**Option A: Cache Size Limits**
- Implement LRU (Least Recently Used) cache with max size
- Clear old entries when cache exceeds threshold

**Option B: Lazy Caching**
- Only cache streams that are accessed multiple times
- Clear cache after operations complete

**Option C: Cache Clearing API**
- Add `Document#clear_cache` method
- Allow manual cache management
- Auto-clear after `flatten`, `clear`, or `write` operations

### Benefits
- **Immediate**: Can free 20-50MB+ for large PDFs with many streams
- **Impact**: Medium-High - Especially important for PDFs with object streams

### Priority
**MEDIUM-HIGH** - Significant memory savings, relatively easy to implement.

---

## 3. All-Objects-in-Memory Operations

### Issue
Operations like `flatten` and `clear` load ALL objects into memory arrays before processing.

### Current Implementation
```ruby
# document.rb line 35-38 (flatten)
objects = []
@resolver.each_object do |ref, body|
  objects << { ref: ref, body: body }  # All objects loaded!
end
```

### Suggested Improvement
**Option A: Streaming Write**
- Write objects directly to output buffer as they're processed
- Don't collect all objects first
- Process and write in single pass

**Option B: Chunked Processing**
- Process objects in batches (e.g., 100 at a time)
- Write batches incrementally
- Reduce peak memory

**Option C: Two-Pass Approach**
- First pass: collect object references and metadata only
- Second pass: read and write object bodies on demand
- Keep object bodies in original file, only read when writing

### Benefits
- **Immediate**: Eliminates need for full object array
- **Impact**: High - Especially for PDFs with many objects (1000+)

### Priority
**HIGH** - Core operations (`flatten`, `clear`) are memory-intensive.

---

## 4. Multiple Full PDF Copies During Write

### Issue
`write` and `flatten` operations create complete new PDFs in memory, doubling memory usage.

### Current Implementation
```ruby
# document.rb line 66-67 (flatten!)
flattened_content = flatten  # New PDF in memory: ~10-20MB
@raw = flattened_content  # Replace original
@resolver = AcroThat::ObjectResolver.new(flattened_content)  # Another copy!
```

### Suggested Improvement
**Option A: Write Directly to File**
- Stream output directly to file instead of building in memory
- Only buffer small chunks at a time

**Option B: Incremental Flattening**
- Rebuild PDF by reading from original and writing to output file
- Never have both in memory simultaneously

**Option C: Temp File for Large Operations**
- For documents >10MB, use temp file
- Stream to temp, then replace original
- Fallback to in-memory for small files

### Benefits
- **Immediate**: 50% reduction during write operations
- **Impact**: Medium - Affects write-heavy workflows

### Priority
**MEDIUM** - Important for write operations, but less critical than load-time memory.

---

## 5. IncrementalWriter Duplicate Original

### Issue
`IncrementalWriter#render` duplicates the entire original PDF before appending patches.

### Current Implementation
```ruby
# incremental_writer.rb line 19
original_with_newline = @orig.dup  # Full copy: ~10-20MB
```

### Suggested Improvement
**Option A: Append Mode**
- Write patches directly to original file (if writable)
- Don't duplicate in memory
- Use file append operations

**Option B: Streaming Append**
- Read original file in chunks
- Write chunks + patches directly to output
- Never have full original in memory

**Option C: Reference Original**
- Only duplicate if original is frozen/immutable
- Use `+""` instead of `dup` for better memory sharing

### Benefits
- **Immediate**: Eliminates ~10-20MB during incremental updates
- **Impact**: Medium - Affects `write` operations

### Priority
**MEDIUM** - Good optimization, but incremental updates are typically small operations.

---

## 6. Object Body String Slicing

### Issue
Every `object_body` call creates new string slices from the original buffer, potentially preventing garbage collection of unused portions.

### Current Implementation
```ruby
# object_resolver.rb line 57-62
hdr = /\bobj\b/m.match(@bytes, i)
after = hdr.end(0)
j = @bytes.index(/\bendobj\b/m, after)
@bytes[after...j]  # New string slice
```

### Suggested Improvement
**Option A: Weak References**
- Use weak references for object bodies
- Allow GC to reclaim original buffer if all references gone

**Option B: Substring Views** (if available)
- Use substring views instead of copying
- Only create copy when string is modified

**Option C: Minimal Caching**
- Don't cache object bodies unless accessed multiple times
- Re-read from file when needed (if streaming)

### Benefits
- **Immediate**: Helps GC reclaim memory faster
- **Impact**: Low-Medium - Affects GC efficiency more than peak memory

### Priority
**LOW-MEDIUM** - Optimization that helps over time, but less critical.

---

## 7. No Memory Limits or Warnings

### Issue
The gem has no way to detect or warn about excessive memory usage before operations fail.

### Current Implementation
No memory monitoring or limits exist.

### Suggested Improvement
**Option A: Memory Estimation**
- Estimate memory usage before operations
- Warn if estimated memory > available
- Suggest alternatives (temp files, etc.)

**Option B: File Size Limits**
- Add configurable file size limits
- Raise error if file exceeds limit
- Prevent loading files that will definitely OOM

**Option C: Memory Monitoring**
- Track peak memory usage during operations
- Log warnings for large memory spikes
- Provide metrics for monitoring

### Benefits
- **Immediate**: Better user experience, fail-fast before OOM
- **Impact**: Medium - Prevents crashes, but doesn't reduce memory

### Priority
**LOW-MEDIUM** - Nice to have, but doesn't fix the root issue.

---

## 8. Field Listing Memory Usage

### Issue
`list_fields` iterates through ALL objects and builds arrays of widget information before returning fields.

### Current Implementation
```ruby
# document.rb line 163-208
@resolver.each_object do |ref, body|  # Iterates ALL objects
  # ... collect widget info in hashes ...
  field_widgets[parent_ref] ||= []
  field_widgets[parent_ref] << widget_info
  # ... more arrays and hashes ...
end
```

### Suggested Improvement
**Option A: Lazy Field Enumeration**
- Return enumerable instead of array
- Calculate field info on-demand
- Only build full array if needed (e.g., `.to_a`)

**Option B: Stream Field Objects**
- Yield fields one at a time instead of collecting
- Process fields as they're discovered
- Use `each_field` method instead of `list_fields`

**Option C: Field Index**
- Build lightweight index (refs only) on first call
- Fetch full field data on-demand
- Cache only frequently accessed fields

### Benefits
- **Immediate**: Reduces memory for documents with many objects
- **Impact**: Medium - Helps when scanning large PDFs

### Priority
**MEDIUM** - Good optimization, but `list_fields` may need to return array for compatibility.

---

## Priority Recommendations

### Critical (Do First)
1. **Duplicate Full PDF (#1)** - Easiest win, immediate 50% reduction
2. **All-Objects-in-Memory Operations (#3)** - Core operations, highest impact

### High Priority
3. **Stream Decompression Cache (#2)** - Significant savings for PDFs with object streams
4. **Multiple Full PDF Copies (#4)** - Affects write operations

### Medium Priority
5. **IncrementalWriter Duplicate (#5)** - Affects incremental updates
6. **Field Listing Memory (#8)** - Optimize field scanning

### Low Priority
7. **Object Body String Slicing (#6)** - GC optimization, less critical
8. **Memory Limits/Warnings (#7)** - Nice to have, doesn't reduce memory

---

## Implementation Strategy

### Phase 1: Quick Wins (Low Risk, High Impact)
1. Eliminate duplicate PDF loading (#1)
2. Clear cache after operations (#2)
3. Add memory estimation/warnings (#7)

### Phase 2: Core Operations (Medium Risk, High Impact)
4. Streaming write for `flatten` (#3)
5. Streaming write for `clear` (#3)
6. Eliminate duplicate during `flatten!` (#4)

### Phase 3: Advanced Optimizations (Higher Risk, Medium Impact)
7. Streaming `IncrementalWriter` (#5)
8. Lazy field enumeration (#8)
9. Memory-mapped files for large documents (#1, Option C)

---

## Testing Considerations

### Memory Profiling
- Use `ObjectSpace.memsize_of` and `GC.stat` to measure improvements
- Profile before/after with real-world PDFs (10MB, 50MB, 100MB+)
- Test with various PDF types (text-only, images, object streams)

### Compatibility
- Ensure all optimizations maintain existing API
- No breaking changes to public methods
- Maintain backward compatibility

### Performance
- Measure impact on processing speed
- Some optimizations (streaming) may slightly reduce speed
- Balance memory vs. performance trade-offs

---

## Notes

- **Ruby String Memory**: Ruby strings have overhead (~24 bytes per string object)
- **GC Pressure**: Multiple large string copies increase GC pressure
- **File Size vs. Memory**: Decompressed streams can be 5-20x larger than compressed size
- **Real-World Limits**: Consider typical server environments (512MB-2GB available)
- **Backward Compatibility**: Must maintain API, but can optimize internals

---

## References

- [Ruby Memory Profiling](https://github.com/SamSaffron/memory_profiler)
- [ObjectSpace Documentation](https://ruby-doc.org/core-3.2.2/ObjectSpace.html)
- [PDF Specification - Object Streams](https://www.adobe.com/content/dam/acom/en/devnet/pdf/pdfs/PDF32000_2008.pdf)

