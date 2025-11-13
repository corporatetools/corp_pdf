# CorpPdf

A minimal pure Ruby library for parsing and editing PDF AcroForm fields.

## Features

- ✅ **Pure Ruby** - Minimal dependencies (only `chunky_png` for PNG image processing)
- ✅ **StringIO Only** - Works entirely in memory, no temp files
- ✅ **PDF AcroForm Support** - Parse, list, add, remove, and modify form fields
- ✅ **Signature Field Images** - Add image appearances to signature fields (JPEG and PNG support)
- ✅ **Minimal PDF Engine** - Basic PDF parser/writer for AcroForm manipulation
- ✅ **Ruby 3.1+** - Modern Ruby support

## Documentation

📚 **Detailed documentation** is available in the [`docs/`](./docs/) directory:

- **[PDF Structure](./docs/pdf_structure.md)** - Understanding PDF file structure and text-based syntax
- **[DictScan Explained](./docs/dict_scan_explained.md)** - How text traversal parses PDF dictionaries
- **[Object Streams](./docs/object_streams.md)** - Parsing compressed PDF object streams
- **[Clearing Fields](./docs/clear_fields.md)** - Complete guide to removing unwanted fields
- **[Documentation Index](./docs/README.md)** - Overview of all available documentation

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'corp_pdf'
```

And then execute:

```bash
bundle install
```

Or install it directly:

```bash
gem install corp_pdf
```

## Usage

### Basic Usage

```ruby
require 'corp_pdf'

# Create a document from a file path or StringIO
doc = CorpPdf::Document.new("form.pdf")

# Or from StringIO
require 'stringio'
pdf_data = File.binread("form.pdf")
io = StringIO.new(pdf_data)
doc = CorpPdf::Document.new(io)

# List all form fields
fields = doc.list_fields
fields.each do |field|
  type_info = field.type_key ? "#{field.type} (:#{field.type_key})" : field.type
  puts "#{field.name} (#{type_info}) = #{field.value}"
end

# Add a new field
new_field = doc.add_field("NameField", 
  value: "John Doe",
  x: 100,
  y: 500,
  width: 200,
  height: 20,
  page: 1,
  type: :text
)

# Update a field value
doc.update_field("ExistingField", "New Value")

# Rename a field while updating it
doc.update_field("OldName", "New Value", new_name: "NewName")

# Remove a field
doc.remove_field("FieldToRemove")

# Write the modified PDF to a file
doc.write("output.pdf")

# Or get PDF bytes as a String (returns String, not StringIO)
pdf_bytes = doc.write
File.binwrite("output.pdf", pdf_bytes)
```

### Advanced Usage

#### Working with Field Objects

Each field returned by `#list_fields` is a `Field` object with properties and methods:

```ruby
doc = CorpPdf::Document.new("form.pdf")
fields = doc.list_fields
field = fields.first

# Access field properties
field.name        # Field name (String)
field.value       # Field value (String or nil)
field.type        # Field type (String, e.g., "/Tx", "/Btn", "/Ch", "/Sig")
field.type_key    # Symbol key (e.g., :text) or nil if not mapped
field.x           # X coordinate (Float or nil)
field.y           # Y coordinate (Float or nil)
field.width       # Field width (Float or nil)
field.height      # Field height (Float or nil)
field.page        # Page number (Integer or nil)
field.ref         # Object reference array [object_number, generation]

# Field methods
field.update("New Value")                    # Update field value
field.update("New Value", new_name: "NewName") # Update and rename
field.remove                                  # Remove the field
field.text_field?                             # Check if text field
field.button_field?                           # Check if button/checkbox field
field.choice_field?                           # Check if choice/dropdown field
field.signature_field?                        # Check if signature field
field.has_value?                              # Check if field has a value
field.has_position?                           # Check if field has position info
field.object_number                           # Get object number
field.generation                              # Get generation number
field.valid_ref?                              # Check if field has valid reference
```

**Note**: When reading fields from a PDF, if the type is missing or empty, it defaults to `"/Tx"` (text field).

#### Signature Fields with Image Appearances

Signature fields can be enhanced with image appearances (signature images). When you update a signature field with image data (base64-encoded JPEG or PNG), CorpPdf will automatically add the image as the field's appearance.

```ruby
doc = CorpPdf::Document.new("form.pdf")

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

#### Radio Buttons

Radio buttons allow users to select a single option from a group of mutually exclusive choices. Radio buttons in CorpPdf are created using the `:radio` type and require a `group_id` to group related buttons together.

```ruby
doc = CorpPdf::Document.new("form.pdf")

# Create a radio button group with multiple options
# All buttons in the same group must share the same group_id

# First radio button in the group (creates the parent field)
doc.add_field("Option1", 
  type: :radio,
  group_id: "my_radio_group",
  value: "option1",  # Export value for this button
  x: 100,
  y: 500,
  width: 20,
  height: 20,
  page: 1,
  selected: true  # This button will be selected by default
)

# Second radio button in the same group
doc.add_field("Option2", 
  type: :radio,
  group_id: "my_radio_group",  # Same group_id as above
  value: "option2",
  x: 100,
  y: 470,
  width: 20,
  height: 20,
  page: 1
)

# Third radio button in the same group
doc.add_field("Option3", 
  type: :radio,
  group_id: "my_radio_group",  # Same group_id
  value: "option3",
  x: 100,
  y: 440,
  width: 20,
  height: 20,
  page: 1
)

# Write the PDF with radio buttons
doc.write("form_with_radio.pdf")
```

**Key Points:**
- **`group_id`**: Required. All radio buttons that should be mutually exclusive must share the same `group_id`. This can be any string or identifier.
- **`type: :radio`**: Required. Specifies that this is a radio button field.
- **`value`**: The export value for this specific button. This is what gets returned when the button is selected. If not provided, a unique value will be generated automatically.
- **`selected`**: Optional boolean (`true` or `false`, or string `"true"`). If set to `true`, this button will be selected by default. Only one button in a group should have `selected: true`. If not specified, the button defaults to unselected.
- **Positioning**: Each radio button needs its own `x`, `y`, `width`, `height`, and `page` values to position it on the form.

**Example with multiple groups:**

```ruby
doc = CorpPdf::Document.new("form.pdf")

# First radio button group (e.g., "Gender")
doc.add_field("Male", type: :radio, group_id: "gender", value: "male", x: 100, y: 500, width: 20, height: 20, page: 1, selected: true)
doc.add_field("Female", type: :radio, group_id: "gender", value: "female", x: 100, y: 470, width: 20, height: 20, page: 1)
doc.add_field("Other", type: :radio, group_id: "gender", value: "other", x: 100, y: 440, width: 20, height: 20, page: 1)

# Second radio button group (e.g., "Age Range")
doc.add_field("18-25", type: :radio, group_id: "age", value: "18-25", x: 200, y: 500, width: 20, height: 20, page: 1)
doc.add_field("26-35", type: :radio, group_id: "age", value: "26-35", x: 200, y: 470, width: 20, height: 20, page: 1, selected: true)
doc.add_field("36+", type: :radio, group_id: "age", value: "36+", x: 200, y: 440, width: 20, height: 20, page: 1)

doc.write("form_with_multiple_groups.pdf")
```

**Note:** Radio buttons are automatically configured with the correct PDF flags to enable mutual exclusivity within a group. When a user selects one radio button, all others in the same group are automatically deselected.

#### Flattening PDFs

Flattening removes incremental updates from a PDF, creating a clean single-version document:

```ruby
doc = CorpPdf::Document.new("form.pdf")

# Flatten in-place (modifies the document)
doc.flatten!

# Get flattened bytes without modifying the document
flattened_bytes = doc.flatten

# Write with flattening option
doc.write("output.pdf", flatten: true)

# Class method: flatten from file
CorpPdf::Document.flatten_pdf("input.pdf", "output.pdf")
flattened_doc = CorpPdf::Document.flatten_pdf("input.pdf")
```

#### Clearing Fields

The `clear` and `clear!` methods completely remove unwanted fields by rewriting the entire PDF (more efficient than multiple `remove_field` calls):

```ruby
doc = CorpPdf::Document.new("form.pdf")

# Remove fields matching a pattern (in-place)
doc.clear!(remove_pattern: /^text-/)

# Keep only specific fields
doc.clear!(keep_fields: ["Name", "Email"])

# Remove specific fields
doc.clear!(remove_fields: ["OldField1", "OldField2"])

# Use a block to filter fields (return true to keep)
doc.clear! { |field| !field.name.start_with?("temp_") }

# Get cleared bytes without modifying document
cleared_bytes = doc.clear(remove_pattern: /.*/)

# Write the cleared PDF
doc.write("cleared.pdf", flatten: true)
```

**Note:** Unlike `remove_field`, which uses incremental updates, `clear` completely rewrites the PDF. See [Clearing Fields Documentation](docs/clear_fields.md) for detailed information.

### API Reference

#### `CorpPdf::Document.new(path_or_io)`
Creates a PDF document from a file path (String) or StringIO object.

```ruby
doc = CorpPdf::Document.new("path/to/file.pdf")
doc = CorpPdf::Document.new(StringIO.new(pdf_bytes))
```

#### `#list_fields`
Returns an array of `Field` objects representing all form fields in the document.

```ruby
fields = doc.list_fields
fields.each do |field|
  puts field.name
end
```

#### `#list_pages`
Returns an array of `Page` objects representing all pages in the document. Each `Page` object provides page information and methods to add fields to that specific page.

```ruby
pages = doc.list_pages
pages.each do |page|
  puts "Page #{page.page_number}: #{page.width}x#{page.height}"
end

# Add fields to specific pages - the page is automatically set!
first_page = pages[0]
first_page.add_field("Name", x: 100, y: 700, width: 200, height: 20)

second_page = pages[1]
second_page.add_field("Email", x: 100, y: 650, width: 200, height: 20)
```

**Page Object Methods:**
- `page.page_number` - Returns the page number (1-indexed)
- `page.width` - Page width in points
- `page.height` - Page height in points
- `page.ref` - Page object reference `[obj_num, gen_num]`
- `page.metadata` - Hash containing page metadata (rotation, boxes, etc.)
- `page.add_field(name, options)` - Add a field to this page (page number is automatically set)
- `page.to_h` - Convert to hash for backward compatibility

#### `#add_field(name, options)`
Adds a new form field to the document. Returns a `Field` object if successful.

**Options:**
- `value`: Default value for the field (String)
- `x`, `y`: Field position coordinates (Integer, defaults: 100, 500)
- `width`, `height`: Field dimensions (Integer, defaults: 100, 20)
- `page`: Page number (Integer, default: 1)
- `type`: Field type (Symbol or String, default: `"/Tx"`)
  - Symbol keys: `:text`, `:button`, `:choice`, `:signature`, `:radio`
  - PDF type strings: `"/Tx"`, `"/Btn"`, `"/Ch"`, `"/Sig"`
- `group_id`: Required for radio buttons. Groups related radio buttons together.
- `selected`: Optional for radio buttons. Set to `true` to select by default.

See [Radio Buttons](#radio-buttons) section for radio button examples.

#### `#update_field(name, new_value, new_name: nil)`
Updates a field's value and optionally renames it. Returns `true` if successful, `false` if field not found.

For signature fields, if `new_value` is base64-encoded JPEG/PNG or a data URI, it automatically adds the image as the field's appearance. See [Signature Fields](#signature-fields-with-image-appearances) section for examples.

#### `#remove_field(name_or_field)`
Removes a form field by name (String) or Field object. Returns `true` if successful, `false` if field not found.

```ruby
doc.remove_field("FieldName")
doc.remove_field(field_object)
```

#### `#write(path_out = nil, flatten: false)`
Writes the modified PDF. If `path_out` is provided, writes to that file path and returns `true`. If no path is provided, returns the PDF bytes as a String. The `flatten` option removes incremental updates from the PDF.

#### `#flatten` and `#flatten!`
Flattening methods. `#flatten` returns flattened PDF bytes without modifying the document. `#flatten!` flattens the PDF in-place.

#### `CorpPdf::Document.flatten_pdf(input_path, output_path = nil)`
Class method to flatten a PDF. If `output_path` is provided, writes to that path and returns the path. Otherwise returns a new `Document` instance with the flattened content.

#### `#clear(options = {})` and `#clear!(options = {})`
Removes unwanted fields by rewriting the entire PDF. `clear` returns cleared PDF bytes without modifying the document, while `clear!` modifies the document in-place.

**Options:**
- `keep_fields`: Array of field names to keep (all others removed)
- `remove_fields`: Array of field names to remove
- `remove_pattern`: Regex pattern - fields matching this are removed
- Block: Given field object, return `true` to keep, `false` to remove

See [Clearing Fields](#clearing-fields) section for examples.

## Example

For complete working examples, see the test files in the `spec/` directory:
- `spec/document_spec.rb` - Basic document operations
- `spec/form_editing_spec.rb` - Form field editing examples
- `spec/field_editor_spec.rb` - Field object manipulation

## Architecture

CorpPdf is built as a minimal PDF engine with the following components:

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