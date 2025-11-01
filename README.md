# AcroThat

A minimal pure Ruby library for parsing and editing PDF AcroForm fields.

## Features

- ✅ **Pure Ruby** - Minimal dependencies (only `chunky_png` for PNG image processing)
- ✅ **StringIO Only** - Works entirely in memory, no temp files
- ✅ **PDF AcroForm Support** - Parse, list, add, remove, and modify form fields
- ✅ **Signature Field Images** - Add image appearances to signature fields (JPEG and PNG support)
- ✅ **Minimal PDF Engine** - Basic PDF parser/writer for AcroForm manipulation
- ✅ **Ruby 3.1+** - Modern Ruby support

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'acro_that'
```

And then execute:

```bash
bundle install
```

Or install it directly:

```bash
gem install acro_that
```

## Usage

### Basic Usage

```ruby
require 'acro_that'

# Create a document from a file path or StringIO
doc = AcroThat::Document.new("form.pdf")

# Or from StringIO
require 'stringio'
pdf_data = File.binread("form.pdf")
io = StringIO.new(pdf_data)
doc = AcroThat::Document.new(io)

# List all form fields
fields = doc.list_fields
fields.each do |field|
  type_info = field.type_key ? "#{field.type} (:#{field.type_key})" : field.type
  puts "#{field.name} (#{type_info}) = #{field.value}"
end

# Add a new field (using symbol key for type)
new_field = doc.add_field("NameField", 
  value: "John Doe",
  x: 100,
  y: 500,
  width: 200,
  height: 20,
  page: 1,
  type: :text  # Optional: :text, :button, :choice, :signature (or "/Tx", "/Btn", etc.)
)

# Or using the PDF type string directly
button_field = doc.add_field("CheckBox", 
  type: "/Btn",  # Or use :button symbol
  x: 100,
  y: 600,
  width: 20,
  height: 20,
  page: 1
)

# Update a field value
doc.update_field("ExistingField", "New Value")

# Rename a field while updating it
doc.update_field("OldName", "New Value", new_name: "NewName")

# Remove a field
doc.remove_field("FieldToRemove")

# Write the modified PDF to a file
doc.write("output.pdf")

# Or write with flattening (removes incremental updates)
doc.write("output.pdf", flatten: true)

# Or get PDF bytes as a String (returns String, not StringIO)
pdf_bytes = doc.write
File.binwrite("output.pdf", pdf_bytes)
```

### Advanced Usage

#### Working with Field Objects

```ruby
doc = AcroThat::Document.new("form.pdf")
fields = doc.list_fields

# Access field properties
field = fields.first
puts field.name        # Field name
puts field.value       # Field value
puts field.type        # Field type (e.g., "/Tx")
puts field.type_key    # Symbol key (e.g., :text) or nil if not mapped
puts field.x           # X position
puts field.y           # Y position
puts field.width       # Width
puts field.height      # Height
puts field.page        # Page number

# Fields default to "/Tx" if type is missing from PDF

# Update a field directly
field.update("New Value")

# Update and rename a field
field.update("New Value", new_name: "NewName")

# Remove a field directly
field.remove

# Check field type
field.text_field?      # true for text fields
field.button_field?    # true for button/checkbox fields
field.choice_field?    # true for choice/dropdown fields
field.signature_field? # true for signature fields

# Check if field has a value
field.has_value?

# Check if field has position information
field.has_position?
```

#### Signature Fields with Image Appearances

Signature fields can be enhanced with image appearances (signature images). When you update a signature field with image data (base64-encoded JPEG or PNG), AcroThat will automatically add the image as the field's appearance.

```ruby
doc = AcroThat::Document.new("form.pdf")

# Add a signature field
sig_field = doc.add_field("MySignature", 
  type: :signature,
  x: 100,
  y: 500,
  width: 200,
  height: 100,
  page: 1
)

# Update signature field with base64-encoded image data
# JPEG example:
jpeg_base64 = Base64.encode64(File.binread("signature.jpg")).strip
doc.update_field("MySignature", jpeg_base64)

# PNG example (requires chunky_png gem):
png_base64 = Base64.encode64(File.binread("signature.png")).strip
doc.update_field("MySignature", png_base64)

# Or using data URI format:
data_uri = "data:image/png;base64,#{png_base64}"
doc.update_field("MySignature", data_uri)

# Write the PDF with the signature appearance
doc.write("form_with_signature.pdf")
```

**Note**: PNG image processing requires the `chunky_png` gem, which is included as a dependency. JPEG images can be processed without any additional dependencies.

#### Flattening PDFs

```ruby
# Flatten a PDF to remove incremental updates
doc = AcroThat::Document.new("form.pdf")
doc.flatten!  # Modifies the document in-place

# Or create a new flattened document
flattened_doc = AcroThat::Document.flatten_pdf("input.pdf", "output.pdf")

# Or get flattened bytes
flattened_bytes = AcroThat::Document.flatten_pdf("input.pdf")
```

#### Clearing Fields

The `clear` and `clear!` methods allow you to completely remove unwanted fields by rewriting the entire PDF:

```ruby
doc = AcroThat::Document.new("form.pdf")

# Remove all fields matching a pattern
doc.clear!(remove_pattern: /^text-/)

# Keep only specific fields
doc.clear!(keep_fields: ["Name", "Email"])

# Remove specific fields
doc.clear!(remove_fields: ["OldField1", "OldField2"])

# Use a block to determine which fields to keep
doc.clear! { |name| !name.start_with?("temp_") }

# Write the cleared PDF
doc.write("cleared.pdf", flatten: true)
```

**Note:** Unlike `remove_field`, which uses incremental updates, `clear` completely rewrites the PDF to exclude unwanted fields. This is more efficient when removing many fields and ensures complete removal. See [Clearing Fields Documentation](docs/cleaning_fields.md) for detailed information.

### API Reference

#### `AcroThat::Document.new(path_or_io)`
Creates a PDF document from a file path (String) or StringIO object.

```ruby
doc = AcroThat::Document.new("path/to/file.pdf")
doc = AcroThat::Document.new(StringIO.new(pdf_bytes))
```

#### `#list_fields`
Returns an array of `Field` objects representing all form fields in the document.

```ruby
fields = doc.list_fields
fields.each do |field|
  puts field.name
end
```

#### `#add_field(name, options)`
Adds a new form field to the document. Options include:
- `value`: Default value for the field (String)
- `x`: X coordinate (Integer, default: 100)
- `y`: Y coordinate (Integer, default: 500)
- `width`: Field width (Integer, default: 100)
- `height`: Field height (Integer, default: 20)
- `page`: Page number to add the field to (Integer, default: 1)
- `type`: Field type (Symbol or String, default: `"/Tx"`). Options:
  - Symbol keys: `:text`, `:button`, `:choice`, `:signature`
  - PDF type strings: `"/Tx"`, `"/Btn"`, `"/Ch"`, `"/Sig"`

Returns a `Field` object if successful.

```ruby
# Using symbol keys (recommended)
field = doc.add_field("NewField", value: "Value", x: 100, y: 500, width: 200, height: 20, page: 1, type: :text)

# Using PDF type strings
field = doc.add_field("ButtonField", type: "/Btn", x: 100, y: 500, width: 20, height: 20, page: 1)
```

#### `#update_field(name, new_value, new_name: nil)`
Updates a field's value and optionally renames it. For signature fields, if `new_value` looks like image data (base64-encoded JPEG/PNG or a data URI), it will automatically add the image as the field's appearance. Returns `true` if successful, `false` if field not found.

```ruby
doc.update_field("FieldName", "New Value")
doc.update_field("OldName", "New Value", new_name: "NewName")

# For signature fields with images:
doc.update_field("SignatureField", base64_image_data)  # Base64-encoded JPEG or PNG
doc.update_field("SignatureField", "data:image/png;base64,...")  # Data URI format
```

#### `#remove_field(name_or_field)`
Removes a form field by name (String) or Field object. Returns `true` if successful, `false` if field not found.

```ruby
doc.remove_field("FieldName")
doc.remove_field(field_object)
```

#### `#write(path_out = nil, flatten: false)`
Writes the modified PDF. If `path_out` is provided, writes to that file path and returns `true`. If no path is provided, returns the PDF bytes as a String. The `flatten` option removes incremental updates from the PDF.

```ruby
doc.write("output.pdf")              # Write to file
doc.write("output.pdf", flatten: true) # Write flattened PDF to file
pdf_bytes = doc.write                 # Get PDF bytes as String
```

#### `#flatten`
Returns flattened PDF bytes (removes incremental updates) without modifying the document.

```ruby
flattened_bytes = doc.flatten
```

#### `#flatten!`
Flattens the PDF in-place (modifies the current document instance).

```ruby
doc.flatten!
```

#### `AcroThat::Document.flatten_pdf(input_path, output_path = nil)`
Class method to flatten a PDF. If `output_path` is provided, writes to that path and returns the path. Otherwise returns a new `Document` instance with the flattened content.

```ruby
AcroThat::Document.flatten_pdf("input.pdf", "output.pdf")
flattened_doc = AcroThat::Document.flatten_pdf("input.pdf")
```

#### `#clear(options = {})` and `#clear!(options = {})`
Removes unwanted fields by rewriting the entire PDF. `clear` returns cleared PDF bytes without modifying the document, while `clear!` modifies the document in-place. Options include:

- `keep_fields`: Array of field names to keep (all others removed)
- `remove_fields`: Array of field names to remove
- `remove_pattern`: Regex pattern - fields matching this are removed
- Block: Given field name, return `true` to keep, `false` to remove

```ruby
# Remove all fields
cleared = doc.clear(remove_pattern: /.*/)

# Remove fields matching pattern (in-place)
doc.clear!(remove_pattern: /^text-/)

# Keep only specific fields
doc.clear!(keep_fields: ["Name", "Email"])

# Use block to filter fields
doc.clear! { |name| !name.match?(/^[a-f0-9-]{30,}/) }
```

**Note:** This completely rewrites the PDF (like `flatten`), so it's more efficient than using `remove_field` multiple times. See [Clearing Fields Documentation](docs/cleaning_fields.md) for detailed information.

### Field Object

Each field returned by `#list_fields` is a `Field` object with the following attributes and methods:

#### Attributes
- `name`: Field name (String)
- `value`: Field value (String or nil)
- `type`: Field type (String, e.g., "/Tx", "/Btn", "/Ch", "/Sig"). Defaults to "/Tx" if missing from PDF.
- `ref`: Object reference array `[object_number, generation]`
- `x`: X coordinate (Float or nil)
- `y`: Y coordinate (Float or nil)
- `width`: Field width (Float or nil)
- `height`: Field height (Float or nil)
- `page`: Page number (Integer or nil)

#### Methods
- `#update(new_value, new_name: nil)`: Update the field's value and optionally rename it
- `#remove`: Remove the field from the document
- `#type_key`: Returns the symbol key for the type (e.g., `:text` for `"/Tx"`) or `nil` if not mapped
- `#text_field?`: Returns true if field is a text field
- `#button_field?`: Returns true if field is a button/checkbox field
- `#choice_field?`: Returns true if field is a choice/dropdown field
- `#signature_field?`: Returns true if field is a signature field
- `#has_value?`: Returns true if field has a non-empty value
- `#has_position?`: Returns true if field has position information
- `#object_number`: Returns the object number (first element of ref)
- `#generation`: Returns the generation number (second element of ref)
- `#valid_ref?`: Returns true if field has a valid reference (not a placeholder)

**Note**: When reading fields from a PDF, if the type is missing or empty, it defaults to `"/Tx"` (text field). The `type_key` method allows you to get the symbol representation (e.g., `:text`) from the type string.

## Example

For complete working examples, see the test files in the `spec/` directory:
- `spec/document_spec.rb` - Basic document operations
- `spec/form_editing_spec.rb` - Form field editing examples
- `spec/field_editor_spec.rb` - Field object manipulation

## Architecture

AcroThat is built as a minimal PDF engine with the following components:

- **ObjectResolver**: Resolves and extracts PDF objects from the document
- **DictScan**: Parses PDF dictionaries and extracts field information
- **IncrementalWriter**: Handles incremental PDF updates (appends changes)
- **PDFWriter**: Writes complete PDF files (for flattening)
- **Actions**: Modular actions for adding, updating, and removing fields (`AddField`, `UpdateField`, `RemoveField`)
- **Document**: Main orchestration class that coordinates all operations
- **Field**: Represents a form field with its properties and methods

## Limitations

This is a minimal implementation focused on AcroForm manipulation. It does not support:

- Complex PDF features (images, fonts, advanced graphics, etc.)
- PDF compression/decompression (streams are preserved as-is)
- Full PDF rendering or display
- Digital signatures (though signature fields can be added)
- JavaScript or other interactive features
- Form submission/validation logic

## Dependencies

- **chunky_png** (~> 1.4): Required for PNG image processing in signature field appearances. JPEG images can be processed without this dependency, but PNG support requires it.

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).