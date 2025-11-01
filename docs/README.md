# AcroThat Documentation

This directory contains detailed documentation about how `AcroThat` works, with a focus on explaining the text-based nature of PDFs and how the library uses simple text traversal to parse and modify them.

## Documentation Overview

### [PDF Structure](./pdf_structure.md)

Explains the fundamental structure of PDF files, including:
- PDFs as text-based files with structured syntax
- PDF dictionaries (`<< ... >>`)
- PDF objects, references, arrays, and strings
- Why PDF structure is parseable with text traversal
- Examples of PDF dictionary structure

**Key insight:** PDFs may contain binary data in streams, but their **structure**—dictionaries, arrays, strings, references—is all text-based syntax.

### [DictScan Explained](./dict_scan_explained.md)

A detailed walkthrough of the `DictScan` module:
- How each function works
- Why text traversal is the core approach
- Step-by-step algorithm explanations
- Common patterns for using `DictScan`
- Examples showing how text traversal parses PDF dictionaries

**Key insight:** Despite appearing complicated, `DictScan` is fundamentally **text traversal**—finding delimiters (`<<`, `>>`, `(`, `)`, etc.) and tracking depth to extract values.

### [Object Streams](./object_streams.md)

Explains how PDF object streams work and how `AcroThat` parses them:
- What object streams are and why they're used
- Object stream structure (header + data sections)
- How `ObjectResolver` identifies objects in streams
- The `ObjStm.parse` algorithm
- Stream decoding (compression, PNG predictor)
- Lazy loading and caching

**Key insight:** Object streams compress multiple objects together, but parsing them is still **text traversal**—once decompressed, it's just parsing space-separated numbers and extracting substrings by offset.

### [Clearing Fields](./cleaning_fields.md)

Documentation for the `clear` and `clear!` methods:
- How to remove unwanted fields completely
- Difference between `clear` and `remove_field`
- Pattern matching and field selection
- Removing orphaned widget references
- Best practices for clearing PDFs

**Key insight:** `clear` rewrites the entire PDF to exclude unwanted fields, ensuring complete removal rather than just marking fields as deleted.

## Common Themes

Throughout all documentation, you'll see these recurring themes:

1. **PDFs are text-based**: Despite being "binary" files, PDF structure uses text syntax
2. **Text traversal works**: Simple character-by-character scanning can parse PDF dictionaries
3. **Depth tracking**: Nested structures (dictionaries, arrays, strings) use depth counting
4. **Position-based replacement**: Using exact byte positions is safer than regex replacement
5. **Minimal parsing**: We don't need a full PDF parser—just enough to find dictionaries and extract/replace values

## How to Read These Docs

**If you're new to PDFs:**
1. Start with [PDF Structure](./pdf_structure.md) to understand PDFs at a high level
2. Read [DictScan Explained](./dict_scan_explained.md) to see how text traversal works
3. Read [Object Streams](./object_streams.md) to understand compression features
4. Read [Clearing Fields](./cleaning_fields.md) to learn how to remove unwanted fields

**If you're debugging:**
- [DictScan Explained](./dict_scan_explained.md) has function-by-function walkthroughs
- [Object Streams](./object_streams.md) explains how object streams are parsed

**If you're contributing:**
- All docs include code examples and algorithm explanations
- Each document explains **why** the approach works, not just **how**

## Technical Details

### Why Text Traversal Works

PDF dictionaries use distinct delimiters:
- `<<` `>>` for dictionaries
- `[` `]` for arrays
- `(` `)` for literal strings
- `<` `>` for hex strings
- `/` for names

These unique delimiters allow pattern-matching on the first character to determine value types. Depth tracking (counting `<<`/`>>`, `[`/`]`, etc.) handles nested structures.

### Performance

**Why text traversal is fast:**
- No AST construction
- No full PDF parsing
- Direct string manipulation
- Minimal memory allocation

**Trade-offs:**
- Doesn't validate entire PDF structure
- Assumes dictionaries are well-formed
- Some preprocessing needed (stream stripping)

### Safety

**Position-based replacement** (using exact byte positions) avoids regex edge cases and preserves formatting. The code verifies dictionaries remain valid after modification.

## Questions?

If you have questions about how `AcroThat` works, these docs should answer them. The code is also well-commented, so reading the source alongside the docs is recommended.

