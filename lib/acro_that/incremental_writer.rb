# frozen_string_literal: true

module AcroThat
  # Appends an incremental update containing the given patches.
  # Each patch is {ref:[num,gen], body:String}
  class IncrementalWriter
    def initialize(original_bytes, patches)
      @orig = original_bytes
      @patches = patches
    end

    def render
      return @orig if @patches.empty?

      startxref_prev = find_startxref(@orig) or raise "startxref not found"
      max_obj = scan_max_obj_number(@orig)

      # Ensure we end with a newline before appending
      # Avoid dup by concatenating instead of modifying in place
      newline_if_needed = @orig.end_with?("\n") ? "".b : "\n".b
      original_with_newline = @orig + newline_if_needed

      buf = +""
      offsets = []

      # Write patches into an object stream for efficiency
      objstm_data = AcroThat::ObjStm.create(@patches, compress: true)
      if objstm_data
        # Get the next object number for the object stream itself
        objstm_num = [max_obj + 1, @patches.map { |p| p[:ref][0] }.max.to_i + 1].max

        # Write the object stream object
        objstm_offset = original_with_newline.bytesize + buf.bytesize
        offsets << [objstm_num, 0, objstm_offset]

        buf << "#{objstm_num} 0 obj\n".b
        buf << objstm_data[:dictionary]
        buf << "\nstream\n".b
        buf << objstm_data[:stream_body]
        buf << "\nendstream\n".b
        buf << "endobj\n".b

        # Build xref stream (supports type 2 entries for objects in object streams)
        sorted_patches = objstm_data[:patches]
        xrefstm_num = objstm_num + 1

        # Collect all entries: object stream itself (type 1) + patches (type 2)
        # Format: [obj_num, gen, type, f1, f2]
        # For type 1: f1 is offset, f2 is generation (unused in xref streams)
        # For type 2: f1 is objstm_num, f2 is index in stream
        entries = []
        # Object stream itself - type 1 entry
        entries << [objstm_num, 0, 1, objstm_offset, 0]
        # Patches in object stream - type 2 entries
        sorted_patches.each_with_index do |patch, index|
          num, gen = patch[:ref]
          next if num == objstm_num # Skip the object stream itself

          entries << [num, gen, 2, objstm_num, index]
        end

        # Sort entries by object number
        entries.sort_by! { |num, gen, _type, _f1, _f2| [num, gen] }

        # Build Index array - use single range for simplicity
        # Index format: [first_obj, count]
        obj_nums = entries.map { |num, _gen, _type, _f1, _f2| num }
        min_obj = obj_nums.min
        max_obj = obj_nums.max

        # For Index, we need consecutive entries from min_obj to max_obj
        # So count is (max_obj - min_obj + 1)
        index_count = max_obj - min_obj + 1
        index_array = [min_obj, index_count]

        # Build xref stream data with proper ordering
        # W = [1, 4, 2] means: type (1 byte), offset/f1 (4 bytes), index/f2 (2 bytes)
        w = [1, 4, 2]

        # Create a map for quick lookup by object number
        entry_map = {}
        entries.each { |num, _gen, type, f1, f2| entry_map[num] = [type, f1, f2] }

        # Build xref records in order according to Index range
        # Index says entries start at min_obj and we have index_count entries
        xref_records = []
        index_count.times do |k|
          obj_num = min_obj + k
          if entry_map[obj_num]
            type, f1, f2 = entry_map[obj_num]
            xref_records << [type, f1, f2].pack("C N n")
          else
            # Type 0 (free) entry for missing objects in the range
            xref_records << [0, 0, 0].pack("C N n")
          end
        end

        xref_bytes = xref_records.join("".b)

        # Compress xref stream
        xref_compressed = Zlib::Deflate.deflate(xref_bytes)

        # Size is max object number + 1 (must include xrefstm_num itself)
        size = [max_obj + 1, objstm_num + 1, xrefstm_num + 1].max

        # Write xref stream object
        xrefstm_offset = original_with_newline.bytesize + buf.bytesize
        root_ref = extract_root_from_trailer(@orig)
        xrefstm_dict = "<<\n/Type /XRef\n/W [#{w.join(' ')}]\n/Size #{size}\n/Index [#{index_array.join(' ')}]\n/Prev #{startxref_prev}\n".b
        xrefstm_dict << " /Root #{root_ref}".b if root_ref
        xrefstm_dict << "\n/Filter /FlateDecode\n/Length #{xref_compressed.bytesize}\n>>\n".b

        buf << "#{xrefstm_num} 0 obj\n".b
        buf << xrefstm_dict
        buf << "stream\n".b
        buf << xref_compressed
        buf << "\nendstream\n".b
        buf << "endobj\n".b

        # Build trailer - need to include xref stream itself
        # The xref stream itself must be accessible, so we use a classic trailer pointing to it
        new_size = [max_obj + 1, xrefstm_num, @patches.map { |p| p[:ref][0] }.max.to_i + 1].max
        xref_offset = xrefstm_offset

        trailer = "trailer\n<< /Size #{new_size} /Prev #{startxref_prev}".b
        trailer << " /Root #{root_ref}".b if root_ref
        trailer << " /XRefStm #{xrefstm_offset} >>\n".b
        trailer << "startxref\n#{xref_offset}\n%%EOF\n".b

        result = original_with_newline + buf + trailer

      else
        # Fallback to individual objects if ObjStm.create fails
        @patches.each do |p|
          num, gen = p[:ref]
          offset = original_with_newline.bytesize + buf.bytesize
          offsets << [num, gen, offset]

          # Write object with proper formatting
          buf << "#{num} #{gen} obj\n"
          buf << p[:body]
          buf << "\nendobj\n"
        end

        # Build xref table
        sorted = offsets.sort_by { |n, g, _| [n, g] }
        xref = +"xref\n"

        i = 0
        while i < sorted.length
          first_num = sorted[i][0]
          run = 1
          while (i + run) < sorted.length && sorted[i + run][0] == first_num + run && sorted[i + run][1] == sorted[i][1]
            run += 1
          end
          xref << "#{first_num} #{run}\n"
          run.times do |r|
            abs = sorted[i + r][2]
            gen = sorted[i + r][1]
            xref << format("%010d %05d n \n", abs, gen)
          end
          i += run
        end

        # Debug: verify xref was built
        if xref == "xref\n"
          raise "Xref table is empty! Offsets: #{offsets.inspect}"
        end

        # Build trailer with /Root reference
        new_size = [max_obj + 1, @patches.map { |p| p[:ref][0] }.max.to_i + 1].max
        xref_offset = original_with_newline.bytesize + buf.bytesize

        # Extract /Root from original trailer
        root_ref = extract_root_from_trailer(@orig)
        root_entry = root_ref ? " /Root #{root_ref}" : ""

        trailer = "trailer\n<< /Size #{new_size} /Prev #{startxref_prev}#{root_entry} >>\nstartxref\n#{xref_offset}\n%%EOF\n"

        result = original_with_newline + buf + xref + trailer

        # Verify xref was built correctly
        if xref.length < 10
          warn "Warning: xref table seems too short (#{xref.length} bytes). Expected proper entries."
        end

      end
      result
    end

    private

    def find_startxref(bytes)
      if bytes =~ /startxref\s+(\d+)\s*%%EOF\s*\z/m
        return Integer(::Regexp.last_match(1))
      end

      m = bytes.rindex("startxref")
      return nil unless m

      tail = bytes[m, bytes.length - m]
      tail[/startxref\s+(\d+)/m, 1]&.to_i
    end

    def scan_max_obj_number(bytes)
      max = 0
      bytes.scan(/(^|\s)(\d+)\s+(\d+)\s+obj\b/) { max = [::Regexp.last_match(2).to_i, max].max }
      max
    end

    def extract_root_from_trailer(bytes)
      # For xref streams, find the last xref stream object dictionary
      startxref_match = bytes.match(/startxref\s+(\d+)\s*%%EOF\s*\z/m)
      if startxref_match
        xref_offset = startxref_match[1].to_i

        # Check if it's an xref stream (starts with object header)
        if bytes[xref_offset, 50] =~ /(\d+\s+\d+\s+obj)/
          # Find the dictionary in the xref stream object
          dict_start = bytes.index("<<", xref_offset)
          if dict_start
            trailer_section = bytes[dict_start, 500]
            if trailer_section =~ %r{/Root\s+(\d+\s+\d+\s+R)}
              return ::Regexp.last_match(1)
            end
          end
        end
      end

      # Fallback: look for classic trailer
      trailer_idx = bytes.rindex("trailer")
      if trailer_idx
        dict_start = bytes.index("<<", trailer_idx)
        if dict_start
          trailer_section = bytes[dict_start, 500]
          if trailer_section =~ %r{/Root\s+(\d+\s+\d+\s+R)}
            return ::Regexp.last_match(1)
          end
        end
      end

      nil
    end
  end
end
