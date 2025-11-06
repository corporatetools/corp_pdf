# Clearing Fields with `clear` and `clear!`

The `clear` method allows you to completely remove unwanted form fields from a PDF by rewriting the entire document, rather than using incremental updates. This is useful when you want to:

- Remove multiple layers of added fields
- Clear a PDF that has accumulated many unwanted fields
- Get back to a base file without certain fields
- Remove orphaned or invalid field references

Unlike `remove_field`, which uses incremental updates, `clear` rewrites the entire PDF (similar to `flatten`) but excludes the unwanted fields entirely. This ensures that:

- Field objects are completely removed (not just marked as deleted)
- Widget annotations are removed from page `/Annots` arrays
- Orphaned widget references are cleaned up
- The AcroForm `/Fields` array is updated
- All references to removed fields are eliminated

## Methods

### `clear(options = {})`

Returns a new PDF with unwanted fields removed. Does not modify the current document.

**Options:**
- `keep_fields`: Array of field names to keep (all others removed)
- `remove_fields`: Array of field names to remove
- `remove_pattern`: Regex pattern - fields matching this are removed
- Block: Given field name, return `true` to keep, `false` to remove

### `clear!(options = {})`

Same as `clear`, but modifies the current document in-place. Mutates the document instance.

## Usage Examples

### Remove All Fields

```ruby
doc = AcroThat::Document.new("form.pdf")

# Remove all fields
cleared_pdf = doc.clear(remove_pattern: /.*/)

# Or in-place
doc.clear!(remove_pattern: /.*/)
```

### Remove Fields Matching a Pattern

```ruby
# Remove all fields starting with "text-"
doc.clear!(remove_pattern: /^text-/)

# Remove UUID-like generated fields
doc.clear! { |name| !(name =~ /text-/ || name =~ /^[a-f0-9]{20,}/) }
```

### Keep Only Specific Fields

```ruby
# Keep only these fields, remove all others
doc.clear!(keep_fields: ["Name", "Email", "Phone"])

# Write the cleared PDF
doc.write("cleared.pdf", flatten: true)
```

### Remove Specific Fields

```ruby
# Remove specific unwanted fields
doc.clear!(remove_fields: ["OldField1", "OldField2", "GeneratedField3"])
```

### Complex Selection with Block

```ruby
# Remove fields matching certain criteria
doc.clear! do |field|
  # Remove fields that look generated
  field.name.start_with?("text-") || 
  field.name.match?(/^[a-f0-9]{20,}/)
end
```

## How It Works

The `clear` method:

1. **Identifies fields to remove** based on the provided criteria (pattern, list, or block)

2. **Finds related widgets** for each field to be removed:
   - Widgets that reference the field via `/Parent`
   - Widgets that have the same name via `/T`

3. **Collects objects to write**, excluding:
   - Field objects that should be removed
   - Widget annotation objects that should be removed

4. **Updates AcroForm structure**:
   - Removes field references from the `/Fields` array
   - Handles both inline and indirect array references

5. **Clears page annotations**:
   - Removes widget references from page `/Annots` arrays
   - Removes orphaned widget references (widgets pointing to non-existent fields)
   - Removes references to widgets that don't exist in the cleared PDF

6. **Rewrites the entire PDF** from scratch (like `flatten`) with only the selected objects

## Key Differences from `remove_field`

| Feature | `remove_field` | `clear` |
|---------|---------------|---------|
| Update Type | Incremental update | Complete rewrite |
| Object Removal | Marks as deleted | Completely excluded |
| PDF Structure | Preserves all objects | Only includes selected objects |
| Use Case | Remove one/a few fields | Remove many fields or clean up |
| Performance | Fast (append only) | Slower (full rewrite) |

## Best Practices

1. **Use `clear` when removing many fields**: If you need to remove a large number of fields, `clear` is more efficient and produces cleaner output.

2. **Always flatten after clearing**: Since `clear` rewrites the PDF, consider using `write(..., flatten: true)` to ensure compatibility with all PDF viewers:

```ruby
doc.clear!(remove_pattern: /^text-/)
doc.write("output.pdf", flatten: true)
```

3. **Combine with field addition**: After clearing, you can add new fields:

```ruby
doc.clear!(remove_pattern: /.*/)
doc.add_field("NewField", value: "Value", x: 100, y: 500, width: 200, height: 20, page: 1)
doc.write("output.pdf", flatten: true)
```

4. **Use patterns for generated fields**: If you have fields with predictable naming patterns (e.g., UUID-based names), use regex patterns:

```ruby
# Remove all UUID-like fields
doc.clear!(remove_pattern: /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/)

# Remove all fields containing "temp" or "test"
doc.clear!(remove_pattern: /temp|test/i)
```

## Technical Details

### Orphaned Widget Removal

The `clear` method automatically identifies and removes orphaned widget references:

- **Non-existent widgets**: Widget references in `/Annots` arrays that point to objects that don't exist
- **Orphaned widgets**: Widgets that reference parent fields that don't exist in the cleaned PDF

This ensures that page annotation arrays don't contain invalid references that could confuse PDF viewers.

### Page Detection

The method correctly identifies actual page objects (`/Type /Page`) and avoids matching page container objects (`/Type /Pages`), ensuring widgets are properly associated with the correct page.

### AcroForm Structure

The method properly handles both:
- **Inline `/Fields` arrays**: Arrays directly in the AcroForm dictionary
- **Indirect `/Fields` arrays**: Arrays referenced as separate objects

Both are updated to remove references to deleted fields.

## Example: Complete Clearing Workflow

```ruby
require 'acro_that'

# Load PDF with many unwanted fields
doc = AcroThat::Document.new("messy_form.pdf")

# Remove all generated/UUID-like fields
doc.clear! { |field| 
  # Remove fields that look generated or temporary
  field.name.match?(/^[a-f0-9-]{30,}/) ||  # UUID-like
  field.name.start_with?("temp_") ||       # Temporary
  field.name.empty?                         # Empty name
}

# Add new fields
doc.add_field("Name", value: "", x: 100, y: 700, width: 200, height: 20, page: 1, type: :text)
doc.add_field("Email", value: "", x: 100, y: 670, width: 200, height: 20, page: 1, type: :text)

# Write cleared and updated PDF
doc.write("cleared_form.pdf", flatten: true)
```

## See Also

- [`flatten` and `flatten!`](./README.md#flattening-pdfs) - Similar rewrite approach for removing incremental updates
- [`remove_field`](../README.md#remove_field) - Incremental removal of single fields
- [Main README](../README.md) - General usage and API reference

