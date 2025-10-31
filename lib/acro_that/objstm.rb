# frozen_string_literal: true

module AcroThat
  class ObjStm
    # Parse an object stream body given N and First.
    # Returns: array like [{ ref:[obj_num,0], body:String }, ...] in order of header listing.
    def self.parse(bytes, n:, first:)
      head = bytes[0...first]
      entries = head.strip.split(/\s+/).map!(&:to_i)
      refs = []
      n.times do |i|
        obj = entries[2 * i]
        off = entries[(2 * i) + 1]
        next_off = i + 1 < n ? entries[(2 * (i + 1)) + 1] : (bytes.bytesize - first)
        body = bytes[first + off, (first + next_off) - (first + off)]
        refs << { ref: [obj, 0], body: body }
      end
      refs
    end

    # Create an object stream from patches (array of {ref: [num, gen], body: String}).
    # Returns: { dictionary: String, stream_body: String, object_count: Integer }
    # The dictionary includes /Type /ObjStm, /N (count), /First (header size), and /Filter /FlateDecode
    def self.create(patches, compress: true)
      return nil if patches.empty?

      # Sort patches by object number for consistency
      sorted_patches = patches.sort_by { |p| p[:ref][0] }

      # Build header: "obj_num offset obj_num offset ..."
      # Offsets are relative to the start of the object data section (after header)
      header_parts = []
      body_parts = []
      current_offset = 0

      sorted_patches.each do |patch|
        obj_num, gen = patch[:ref]
        body = patch[:body].to_s
        # Ensure body ends with newline for proper parsing
        body = body + "\n" unless body.end_with?("\n")

        header_parts << obj_num.to_s
        header_parts << current_offset.to_s
        body_parts << body
        current_offset += body.bytesize
      end

      header = header_parts.join(" ") + "\n"
      first = header.bytesize
      object_bodies = body_parts.join("")

      # Combine header and bodies
      raw_data = header + object_bodies

      # Compress if requested
      stream_body = if compress
                      Zlib::Deflate.deflate(raw_data)
                    else
                      raw_data
                    end

      # Build dictionary
      dict = "<<\n/Type /ObjStm\n/N #{sorted_patches.length}\n/First #{first}".b
      dict << "\n/Filter /FlateDecode".b if compress
      dict << "\n/Length #{stream_body.bytesize}\n>>".b

      {
        dictionary: dict,
        stream_body: stream_body.b,
        object_count: sorted_patches.length,
        patches: sorted_patches
      }
    end
  end
end
