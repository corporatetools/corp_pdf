# Code Review Issues

This folder contains documentation of code cleanup, refactoring opportunities, and improvement tasks found in the codebase.

## Files

- **[refactoring-opportunities.md](./refactoring-opportunities.md)** - Detailed list of code duplication and refactoring opportunities
- **[memory-improvements.md](./memory-improvements.md)** - Memory usage issues and optimization opportunities for handling larger PDF documents

## Summary

### High Priority Issues
1. **Widget Matching Logic** - Duplicated across 6+ locations
2. **/Annots Array Manipulation** - Complex logic duplicated in 3 locations

### Medium Priority Issues
3. **Box Parsing Logic** - Repeated code blocks for 5 box types
4. **Checkbox Appearance Creation** - Significant duplication in new code
5. **PDF Metadata Formatting** - Could benefit from being shared utilities

### Low Priority Issues
6. Duplicated `next_fresh_object_number` implementation (may be intentional)
7. Object reference extraction pattern duplication
8. Unused method: `get_widget_rect_dimensions`
9. Base64 decoding logic duplication

### Completed ✅
- **Page-Finding Logic** - Successfully refactored into `DictScan.is_page?` and unified page-finding methods

## Quick Stats

- **10 refactoring opportunities** identified (1 completed, 9 remaining)
- **6+ locations** with widget matching duplication
- **3 locations** with /Annots array manipulation duplication
- **1 unused method** found
- **2 new issues** identified in recent code additions

## Memory & Performance

### Memory Improvement Opportunities

See **[memory-improvements.md](./memory-improvements.md)** for detailed analysis of memory usage and optimization strategies.

**Key Issues:**
- Duplicate PDF loading (2x memory usage)
- Stream decompression cache retention
- All-objects-in-memory operations
- Multiple full PDF copies during write operations

**Estimated Impact:** 50-90MB typical usage for 10MB PDF, can exceed 100-200MB+ for larger/complex PDFs (39+ pages).

## Next Steps

1. Review [refactoring-opportunities.md](./refactoring-opportunities.md) for detailed information
2. Review [memory-improvements.md](./memory-improvements.md) for memory optimization strategies
3. Prioritize improvements based on maintenance and performance needs
4. Create test coverage before refactoring
5. Implement improvements incrementally, starting with high-priority items

