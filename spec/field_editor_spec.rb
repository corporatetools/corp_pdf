# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe AcroThat::Document do
  let(:test_pdf_path) { "/Users/2b-software-mac/Documents/work/acro-that/Stamford_Trade-Name-Dissolution.pdf" }
  let(:temp_output_path) { Tempfile.new(["test_output", ".pdf"]).path }

  before do
    # Clean up temp file
    FileUtils.rm_f(temp_output_path)
  end

  after do
    # Clean up temp file
    FileUtils.rm_f(temp_output_path)
  end

  describe ".list_fields" do
    context "with Stamford_Trade-Name-Dissolution.pdf" do
      it "lists all 11 expected fields" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        doc = described_class.new(test_pdf_path)
        fields = doc.list_fields

        expect(fields).to be_an(Array)
        expect(fields.length).to eq(11)

        field_names = fields.map(&:name).compact
        expected_names = [
          "Trade Name",
          "File",
          "Name",
          "Residence Address",
          "Name_2",
          "Residence Address_2",
          "Name_3",
          "Residence Address_3",
          "Date60_af_date",
          "BusinessType",
          "Businessaddress"
        ]

        expect(field_names).to match_array(expected_names)
      end

      it "returns field information with correct structure" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        doc = described_class.new(test_pdf_path)
        fields = doc.list_fields

        fields.each do |field|
          expect(field).to respond_to(:name)
          expect(field).to respond_to(:value)
          expect(field).to respond_to(:type)
          expect(field.name).to be_a(String)
        end
      end
    end

    context "with files without object streams" do
      it "still works with regular PDF files" do
        # This would need a test PDF without object streams
        # For now, we'll test that the method doesn't crash
        skip "Need test PDF without object streams"
      end
    end
  end

  describe ".set_field" do
    context "with Stamford_Trade-Name-Dissolution.pdf" do
      it "sets text field value" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        success = described_class.set_field(test_pdf_path, temp_output_path, "Trade Name", "Acme Tools")

        expect(success).to be true
        expect(File.exist?(temp_output_path)).to be true

        # Verify the field was set by reading the output file
        output_fields = described_class.list_fields(temp_output_path)
        trade_name_field = output_fields.find { |f| f[:name] == "Trade Name" }

        expect(trade_name_field).not_to be_nil
        expect(trade_name_field[:value]).to eq("Acme Tools")
      end

      it "handles checkbox/radio fields" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        # Find a checkbox field (if any exist)
        fields = described_class.list_fields(test_pdf_path)
        checkbox_field = fields.find { |f| ["/Btn", "/Ch"].include?(f[:type]) }

        if checkbox_field
          success = described_class.set_field(test_pdf_path, temp_output_path, checkbox_field[:name], true)
          expect(success).to be true

          # Verify the field was set
          output_fields = described_class.list_fields(temp_output_path)
          updated_field = output_fields.find { |f| f[:name] == checkbox_field[:name] }
          expect(updated_field[:value]).to eq("/Yes")
        else
          skip "No checkbox fields found in test PDF"
        end
      end

      it "creates incremental update without full rewrite" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        original_size = File.size(test_pdf_path)

        success = described_class.set_field(test_pdf_path, temp_output_path, "Trade Name", "Test Value")

        expect(success).to be true

        # The output should be larger than original (incremental update)
        output_size = File.size(temp_output_path)
        expect(output_size).to be > original_size

        # Verify the file structure contains incremental update
        output_content = File.read(temp_output_path, mode: "rb")
        expect(output_content).to include("xref")
        expect(output_content).to include("trailer")
        expect(output_content).to include("startxref")
        expect(output_content).to include("%%EOF")
      end
    end
  end

  describe ".remove_field" do
    context "with Stamford_Trade-Name-Dissolution.pdf" do
      it "removes a field successfully" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        # First verify the field exists
        original_fields = described_class.list_fields(test_pdf_path)
        field_to_remove = original_fields.find { |f| f[:name] == "Name_3" }
        expect(field_to_remove).not_to be_nil

        # Remove the field
        success = described_class.remove_field(test_pdf_path, temp_output_path, "Name_3")
        expect(success).to be true

        # Verify the field was removed
        output_fields = described_class.list_fields(temp_output_path)
        removed_field = output_fields.find { |f| f[:name] == "Name_3" }
        expect(removed_field).to be_nil

        # Verify other fields still exist
        expect(output_fields.length).to eq(original_fields.length - 1)
      end

      it "creates incremental update for field removal" do
        skip "Test file not available" unless File.exist?(test_pdf_path)

        original_size = File.size(test_pdf_path)

        success = described_class.remove_field(test_pdf_path, temp_output_path, "Name_3")
        expect(success).to be true

        # The output should be larger than original (incremental update)
        output_size = File.size(temp_output_path)
        expect(output_size).to be > original_size

        # Verify the file is still valid PDF
        output_content = File.read(temp_output_path, mode: "rb")
        expect(output_content).to start_with("%PDF-")
        expect(output_content).to end_with("%%EOF\n")
      end
    end
  end

  describe "backward compatibility" do
    it "maintains compatibility with existing API" do
      # Test that the new implementation doesn't break existing functionality
      skip "Need to verify existing API still works"
    end
  end

  describe "error handling" do
    it "handles non-existent files gracefully" do
      expect do
        described_class.list_fields("/non/existent/file.pdf")
      end.to raise_error(Errno::ENOENT)
    end

    it "handles invalid PDF files gracefully" do
      temp_file = Tempfile.new(["invalid", ".pdf"])
      temp_file.write("Not a PDF file")
      temp_file.close

      expect do
        described_class.list_fields(temp_file.path)
      end.to raise_error(AcroThat::UnsupportedFilterError)

      temp_file.unlink
    end

    it "handles non-existent field names gracefully" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      success = described_class.set_field(test_pdf_path, temp_output_path, "NonExistentField", "value")
      expect(success).to be false
    end
  end
end

RSpec.describe AcroThat::ObjectResolver do
  let(:test_pdf_path) { "/Users/2b-software-mac/Documents/work/acro-that/Stamford_Trade-Name-Dissolution.pdf" }

  describe "#initialize" do
    it "accepts file path" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      resolver = described_class.new(test_pdf_path)
      expect(resolver).to be_a(described_class)
    end

    it "accepts IO object" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      file = File.open(test_pdf_path, "rb")
      resolver = described_class.new(file)
      expect(resolver).to be_a(described_class)
      file.close
    end

    it "accepts StringIO" do
      content = File.read(test_pdf_path, mode: "rb")
      io = StringIO.new(content)
      resolver = described_class.new(io)
      expect(resolver).to be_a(described_class)
    end
  end

  describe "#object" do
    it "resolves regular objects" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      resolver = described_class.new(test_pdf_path)

      # Find a regular object reference
      obj_ref = resolver.xref_entries.find { |(_num, _gen), entry| entry[:type] == :in_file }
      expect(obj_ref).not_to be_nil

      obj_num, obj_gen = obj_ref[0]
      obj_data = resolver.object({ num: obj_num, gen: obj_gen })

      expect(obj_data).to be_a(Hash)
      expect(obj_data[:num]).to eq(obj_num)
      expect(obj_data[:gen]).to eq(obj_gen)
      expect(obj_data[:in_objstm]).to be false
    end

    it "resolves object stream objects" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      resolver = described_class.new(test_pdf_path)

      # Find an object stream object reference
      obj_ref = resolver.xref_entries.find { |(_num, _gen), entry| entry[:type] == :in_objstm }

      if obj_ref
        obj_num, obj_gen = obj_ref[0]
        obj_data = resolver.object({ num: obj_num, gen: obj_gen })

        expect(obj_data).to be_a(Hash)
        expect(obj_data[:num]).to eq(obj_num)
        expect(obj_data[:gen]).to eq(obj_gen)
        expect(obj_data[:in_objstm]).to be true
        expect(obj_data[:container_ref]).to be_a(Hash)
        expect(obj_data[:index_in_objstm]).to be_a(Integer)
      else
        skip "No object stream objects found in test PDF"
      end
    end
  end

  describe "#trailer" do
    it "returns trailer dictionary" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      resolver = described_class.new(test_pdf_path)
      trailer = resolver.trailer

      expect(trailer).to be_a(Hash)
      expect(trailer).to have_key("/Root")
      expect(trailer).to have_key("/Size")
    end
  end

  describe "#xref_entries" do
    it "returns xref entries hash" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      resolver = described_class.new(test_pdf_path)
      entries = resolver.xref_entries

      expect(entries).to be_a(Hash)
      expect(entries).not_to be_empty

      entries.each do |(obj_num, obj_gen), entry|
        expect(obj_num).to be_a(Integer)
        expect(obj_gen).to be_a(Integer)
        expect(entry).to have_key(:type)
        expect(%i[in_file in_objstm]).to include(entry[:type])
      end
    end
  end
end

RSpec.describe AcroThat::ObjStm do
  describe ".parse" do
    it "parses object stream correctly" do
      # Create a mock object stream
      n = 3
      first = 20

      # Mock header: "1 0 2 5 3 10"
      header = "1 0 2 5 3 10"

      # Mock object data
      obj1 = "<< /Type /Annot /T (Field1) >>"
      obj2 = "<< /Type /Annot /T (Field2) >>"
      obj3 = "<< /Type /Annot /T (Field3) >>"

      object_data = obj1 + obj2 + obj3
      container_bytes = header + object_data

      objects = described_class.parse(container_bytes, n: n, first: first)

      expect(objects).to be_an(Array)
      expect(objects.length).to eq(3)

      expect(objects[0][:ref]).to eq([1, 0])
      expect(objects[0][:body]).to eq(obj1)

      expect(objects[1][:ref]).to eq([2, 0])
      expect(objects[1][:body]).to eq(obj2)

      expect(objects[2][:ref]).to eq([3, 0])
      expect(objects[2][:body]).to eq(obj3)
    end
  end
end

RSpec.describe AcroThat::DictScan do
  describe ".strip_stream_bodies" do
    it "replaces stream bodies with sentinel" do
      input = "stream\nHello World\nendstream"
      output = described_class.strip_stream_bodies(input)

      expect(output).to eq("stream\n<STREAM_BODY>\nendstream")
    end
  end

  describe ".each_dictionary" do
    it "finds balanced dictionary blocks" do
      input = "<< /Type /Annot /T (Field1) >> some text << /Type /Page >>"
      dictionaries = []

      described_class.each_dictionary(input) do |dict_src|
        dictionaries << dict_src
      end

      expect(dictionaries.length).to eq(2)
      expect(dictionaries[0]).to include("/Type /Annot")
      expect(dictionaries[1]).to include("/Type /Page")
    end
  end

  describe ".value_token_after" do
    it "extracts value after key" do
      dict_src = "/Type /Annot /T (FieldName) /FT /Tx"

      type_value = described_class.value_token_after("/Type", dict_src)
      expect(type_value).to eq("/Annot")

      t_value = described_class.value_token_after("/T", dict_src)
      expect(t_value).to eq("(FieldName)")
    end
  end

  describe ".decode_pdf_string" do
    it "decodes literal strings" do
      result = described_class.decode_pdf_string("(Hello World)")
      expect(result).to eq("Hello World")
    end

    it "decodes hex strings" do
      result = described_class.decode_pdf_string("<48656C6C6F>")
      expect(result).to eq("Hello")
    end

    it "handles UTF-16BE with BOM" do
      # UTF-16BE "Hello" with BOM
      hex_string = "<FEFF00480065006C006C006F>"
      result = described_class.decode_pdf_string(hex_string)
      expect(result).to eq("Hello")
    end

    it "handles escape sequences" do
      result = described_class.decode_pdf_string("(Hello\\nWorld)")
      expect(result).to eq("Hello\nWorld")
    end
  end
end

RSpec.describe AcroThat::IncrementalWriter do
  let(:test_pdf_path) { "/Users/2b-software-mac/Documents/work/acro-that/Stamford_Trade-Name-Dissolution.pdf" }

  describe "#write" do
    it "writes incremental update" do
      skip "Test file not available" unless File.exist?(test_pdf_path)

      input_io = File.open(test_pdf_path, "rb")
      patches = [
        {
          type: :replace_object,
          obj_num: 999,
          obj_gen: 0,
          new_body: "<< /Type /Annot /T (TestField) >>"
        }
      ]

      writer = described_class.new(input_io, patches)
      output_io = StringIO.new

      success = writer.write(output_io)
      expect(success).to be true

      output_content = output_io.string
      expect(output_content).to include("999 0 obj")
      expect(output_content).to include("<< /Type /Annot /T (TestField) >>")
      expect(output_content).to include("xref")
      expect(output_content).to include("trailer")
      expect(output_content).to include("startxref")
      expect(output_content).to end_with("%%EOF\n")

      input_io.close
    end
  end
end
