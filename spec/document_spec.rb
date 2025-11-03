# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe AcroThat::Document do
  describe "#new" do
    it "creates a document from a real PDF file" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      doc = described_class.new(pdf_path)

      expect(doc).to be_a(described_class)
      fields = doc.list_fields
      expect(fields).to be_an(Array)
    end

    it "creates a document from StringIO" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      io = StringIO.new(File.binread(pdf_path))
      doc = described_class.new(io)

      expect(doc).to be_a(described_class)
      fields = doc.list_fields
      expect(fields).to be_an(Array)
      expect(fields.length).to be > 0
    end

    it "lists form fields from example PDF" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      doc = described_class.new(pdf_path)
      fields = doc.list_fields

      expect(fields).to be_an(Array)
      expect(fields.length).to be > 0
      expect(fields.first).to be_a(AcroThat::Field)
      expect(fields.first.name).to be_a(String)
    end

    it "removes a non-existent field" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      doc = described_class.new(pdf_path)
      initial_count = doc.list_fields.length

      # Try to remove a non-existent field
      result = doc.remove_field("NonExistentField")
      remaining_fields = doc.list_fields

      expect(result).to be false
      expect(remaining_fields.length).to eq(initial_count)
    end

    it "removes a field from a document" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      doc = described_class.new(pdf_path)
      initial_count = doc.list_fields.length

      # Try to remove a field
      first_field = doc.list_fields.first
      field_name = first_field.name
      result = first_field.remove

      expect(result).to be true

      # Write to temp file and verify persistence by reloading
      temp_file = Tempfile.new(["test_remove_field", ".pdf"])
      begin
        doc.write(temp_file.path)

        # Reload and verify
        doc2 = described_class.new(temp_file.path)
        remaining_fields = doc2.list_fields

        expect(remaining_fields.length).to eq(initial_count - 1)
        removed_field = remaining_fields.find { |f| f.name == field_name }
        expect(removed_field).to be_nil
      ensure
        temp_file.unlink
      end
    end

    it "adds a field to a document" do
      pdf_path = File.join(__dir__, "fixtures", "form.pdf")
      expect(File.exist?(pdf_path)).to be true

      doc = described_class.new(pdf_path)
      initial_count = doc.list_fields.length

      # Add a new field
      new_field_name = "TestAddedField_#{Time.now.to_i}"
      new_field = doc.add_field(new_field_name, value: "Test Value", x: 100, y: 500, width: 200, height: 20, page: 1)

      expect(new_field).to be_a(AcroThat::Field)
      expect(new_field.name).to eq(new_field_name)
      expect(new_field.value).to eq("Test Value")

      # Write to temp file and verify persistence by reloading
      temp_file = Tempfile.new(["test_add_field", ".pdf"])
      begin
        doc.write(temp_file.path, flatten: true)

        # Reload and verify
        doc2 = described_class.new(temp_file.path)
        new_fields = doc2.list_fields

        added_field = new_fields.find { |f| f.name == new_field_name }
        expect(added_field.value).to eq("Test Value")
        expect(added_field.text_field?).to be true
        expect(new_fields.length).to eq(initial_count + 1)
      ensure
        temp_file.unlink
      end
    end
  end
end
