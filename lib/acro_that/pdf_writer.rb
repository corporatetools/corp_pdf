# frozen_string_literal: true

module AcroThat
  # PDFWriter - Clean PDF writer for flattening documents
  # Writes a complete PDF from parsed objects, consolidating incremental updates
  class PDFWriter
    def initialize
      # Work entirely in binary encoding to avoid UTF-8/ASCII-8BIT conflicts
      @buffer = "".b
      @offsets = [] # Track [obj_num, gen, offset] for xref table
      @xref_offset = 0
    end

    def write_header
      @buffer << "%PDF-1.6\n".b
      # Binary marker (helps PDF readers identify binary content)
      @buffer << "%\xE2\xE3\xCF\xD3\n".b
    end

    def write_object(ref, body)
      obj_num, gen = ref
      offset = @buffer.bytesize
      @offsets << [obj_num, gen, offset]

      # Write object with proper PDF syntax
      # Use ASCII-8BIT encoding throughout to avoid conflicts
      @buffer << "#{obj_num} #{gen} obj\n".b

      # Body is already in binary from ObjectResolver
      @buffer << body.b

      # Ensure proper spacing before endobj
      @buffer << "\n".b unless body.end_with?("\n")
      @buffer << "endobj\n".b
    end

    def write_xref
      @xref_offset = @buffer.bytesize

      # Build xref table
      xref = "xref\n".b

      # Object 0 (free list head)
      xref << "0 1\n".b
      xref << "0000000000 65535 f \n".b

      # Sort offsets and group consecutive objects into subsections
      sorted = @offsets.sort_by { |num, gen, _offset| [num, gen] }

      # Find max object number to determine Size
      max_obj_num = sorted.map { |num, _gen, _offset| num }.max || 0

      # Build xref entries covering all objects from 0 to max_obj_num
      # Missing objects are marked as free (type 'f')
      i = 0
      current_obj = 0

      while current_obj <= max_obj_num
        # Find next existing object
        next_existing = sorted.find { |num, _gen, _offset| num >= current_obj }
        
        if next_existing && next_existing[0] == current_obj
          # Object exists - find consecutive run of existing objects
          first_num = current_obj
          run_length = 1
          
          while (i + run_length) < sorted.length &&
                sorted[i + run_length][0] == first_num + run_length &&
                sorted[i + run_length][1] == sorted[i][1]
            run_length += 1
          end

          # Write subsection header
          xref << "#{first_num} #{run_length}\n".b

          # Write entries in this subsection
          run_length.times do |j|
            offset = sorted[i + j][2]
            gen = sorted[i + j][1]
            xref << format("%010d %05d n \n", offset, gen).b
          end

          i += run_length
          current_obj = first_num + run_length
        else
          # Object doesn't exist - find consecutive run of missing objects
          first_missing = current_obj
          missing_count = 1
          
          while current_obj + missing_count <= max_obj_num
            check_obj = current_obj + missing_count
            if sorted.any? { |num, _gen, _offset| num == check_obj }
              break
            end
            missing_count += 1
          end

          # Write subsection header for missing objects
          xref << "#{first_missing} #{missing_count}\n".b

          # Write free entries
          missing_count.times do
            xref << "0000000000 65535 f \n".b
          end

          current_obj = first_missing + missing_count
        end
      end

      @buffer << xref
    end

    def write_trailer(size, root_ref, info_ref = nil)
      trailer = "trailer\n".b
      trailer << "<<".b
      trailer << " /Size #{size}".b
      trailer << " /Root #{root_ref[0]} #{root_ref[1]} R".b
      trailer << " /Info #{info_ref[0]} #{info_ref[1]} R".b if info_ref
      trailer << " >>".b
      trailer << "\n".b
      trailer << "startxref\n".b
      trailer << "#{@xref_offset}\n".b
      trailer << "%%EOF\n".b

      @buffer << trailer
    end

    def output
      @buffer
    end
  end
end
