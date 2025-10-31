# frozen_string_literal: true

module AcroThat
  # Parses xref (tables and streams) and exposes object bodies uniformly,
  # including objects embedded in /ObjStm. Also gives you the trailer and /Root.
  class ObjectResolver
    Entry = Struct.new(:type, :offset, :objstm_num, :objstm_index, keyword_init: true)

    def initialize(bytes)
      @bytes = bytes
      @entries = {}
      @objstm_cache = {}
      parse_cross_reference
    end

    def root_ref
      tr = trailer_dict
      return nil unless tr =~ %r{/Root\s+(\d+)\s+(\d+)\s+R}

      [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
    end

    def trailer_dict
      # Priority order:
      # 1. Explicit trailer from classic xref (incremental updates)
      # 2. Xref stream dictionary (original PDFs)
      # 3. Search for trailer (fallback)
      @trailer_dict ||= if @trailer_explicit
                          @trailer_explicit
                        elsif @last_xref_stream_dict
                          @last_xref_stream_dict
                        else
                          # Find last 'trailer << ... >>' before last startxref
                          start = find_startxref(@bytes) || 0
                          head = @bytes[0...start]
                          idx = head.rindex("trailer")
                          raise "trailer not found" unless idx

                          # naive grab following dict
                          m = head.index("<<", idx)
                          n = balanced_from(head, m)
                          head[m...n]
                        end
    end

    def each_object
      @entries.each_key do |ref|
        yield(ref, object_body(ref))
      end
    end

    def object_body(ref)
      case (e = @entries[ref])&.type
      when :in_file
        i = e.offset
        # Find "obj" start near offset (handle any preceding whitespace)
        hdr = /\bobj\b/m.match(@bytes, i) or return nil
        after = hdr.end(0)
        # Skip optional whitespace and one line break if present
        after += 1 while (ch = @bytes.getbyte(after)) && ch <= 0x20
        j = @bytes.index(/\bendobj\b/m, after) or return nil
        @bytes[after...j]
      when :in_objstm
        load_objstm([e.objstm_num, 0])
        @objstm_cache[[e.objstm_num, 0]][e.objstm_index][:body]
      end
    end

    # --- internals -----------------------------------------------------------

    def parse_cross_reference
      start = find_startxref(@bytes) or raise "startxref not found"
      parse_xref_at_offset(start)
    end

    def parse_xref_at_offset(offset)
      # 1) If 'xref' is literally at that offset => classic table
      if @bytes[offset, 4] == "xref"
        tr = parse_classic_xref(offset)

        # 2) Classic trailers may include /XRefStm <offset> to an xref stream with compressed entries
        xrefstm_tok = DictScan.value_token_after("/XRefStm", tr) if tr
        if xrefstm_tok && (ofs = xrefstm_tok.to_i).positive?
          parse_xref_stream_at(ofs) # merge entries from xref stream (type 0/1/2)
        end

        # 3) Follow /Prev pointer if present
        prev_tok = DictScan.value_token_after("/Prev", tr) if tr
        if prev_tok && (prev_ofs = prev_tok.to_i).positive?
          parse_xref_at_offset(prev_ofs)
        end
      else
        # Direct xref stream case (offset points to the xref stream obj header)
        dict_src = parse_xref_stream_at(offset)

        # Follow /Prev in the xref stream's dictionary
        if dict_src
          prev_tok = DictScan.value_token_after("/Prev", dict_src)
          if prev_tok && (prev_ofs = prev_tok.to_i).positive?
            parse_xref_at_offset(prev_ofs)
          end
        end
      end
    end

    def parse_classic_xref(start)
      pos = @bytes.rindex("xref", start) or raise "xref not found"
      i = pos + 4

      loop do
        m = /\s*(\d+)\s+(\d+)/m.match(@bytes, i) or break
        first = m[1].to_i
        count = m[2].to_i
        i = m.end(0)

        count.times do |k|
          # Skip whitespace/newlines before reading the 20-byte record
          i += 1 while (ch = @bytes.getbyte(i)) && [0x0A, 0x0D, 0x20].include?(ch)

          rec = @bytes[i, 20]
          raise "bad xref record" unless rec && rec.bytesize == 20

          off = rec[0, 10].to_i
          gen = rec[11, 5].to_i
          typ = rec[17, 1]
          i += 20
          # consume line ending(s)
          i += 1 while (ch = @bytes.getbyte(i)) && [0x0A, 0x0D].include?(ch)

          ref = [first + k, gen]
          @entries[ref] ||= Entry.new(type: :in_file, offset: off) if typ == "n"
          # (ignore 'f' free entries)
        end

        break if @bytes[i, 7] == "trailer"
      end

      tpos = @bytes.index("trailer", i)
      if tpos
        dpos = @bytes.index("<<", tpos)
        if dpos
          dend = balanced_from(@bytes, dpos)
          @last_xref_stream_dict = nil
          @trailer_explicit = @bytes[dpos...dend]
          return @trailer_explicit
        end
      end

      # No trailer found (might be at an intermediate xref in the chain)
      nil
    end

    def parse_xref_stream_at(header_ofs)
      # Expect "<num> <gen> obj" at header_ofs
      m = /\A(\d+)\s+(\d+)\s+obj\b/m.match(@bytes[header_ofs, 50])
      unless m
        # Sometimes header_ofs might land on whitespace; search forward a bit
        win = @bytes[header_ofs, 256]
        m2 = /(\d+)\s+(\d+)\s+obj\b/m.match(win) or raise "xref stream header not found"
        header_ofs += m2.begin(0)
        m = m2
      end
      obj_ref = [m[1].to_i, m[2].to_i]

      dpos = @bytes.index("<<", header_ofs + m[0].length) or raise "xref stream dict missing"
      dend = balanced_from(@bytes, dpos)
      dict_src = @bytes[dpos...dend]
      @last_xref_stream_dict ||= dict_src # Keep first one for trailer_dict

      spos = @bytes.index(/\bstream\r?\n/m, dend) or raise "xref stream body missing"
      epos = @bytes.index(/\bendstream\b/m, spos) or raise "xref stream end missing"
      data = @bytes[spos..epos]
      raw = decode_stream_data(dict_src, data)

      # W is mandatory in xref streams; if missing, bail (don't crash)
      w_tok = DictScan.value_token_after("/W", dict_src)
      return nil unless w_tok

      w = JSON_like_array(w_tok)
      idx_tok = DictScan.value_token_after("/Index", dict_src)
      index = idx_tok ? JSON_like_array(idx_tok) : [0, DictScan.value_token_after("/Size", dict_src).to_i]

      parse_xref_stream_records(raw, w, index)

      # Ensure the xref stream object itself is registered (type 1 entry usually exists,
      # but if not, add it so object_body can find the stream if needed)
      unless @entries.key?(obj_ref)
        # Approximate offset at header_ofs
        @entries[obj_ref] = Entry.new(type: :in_file, offset: header_ofs)
      end

      dict_src # Return dict for /Prev checking
    end

    def parse_xref_stream_records(raw, w, index)
      w0, w1, w2 = w
      s = StringScanner.new(raw)
      (0...(index.length / 2)).each do |i|
        obj = index[2 * i].to_i
        count = index[(2 * i) + 1].to_i
        count.times do |k|
          t  = read_int(s, w0)
          f1 = read_int(s, w1)
          f2 = read_int(s, w2)
          ref = [obj + k, 0]
          case t
          when 0 then next # free
          when 1 then @entries[ref] ||= Entry.new(type: :in_file, offset: f1)
          when 2 then @entries[ref] ||= Entry.new(type: :in_objstm, objstm_num: f1, objstm_index: f2)
          end
        end
      end
    end

    def read_int(scanner, width)
      # Ensure width is an integer
      w = width.is_a?(Integer) ? width : width.to_i
      return 0 if w.zero?

      bytes = scanner.peek(w)
      return 0 unless bytes && bytes.bytesize == w

      scanner.pos += w
      val = 0
      bytes.each_byte { |b| val = (val << 8) | b }
      val
    end

    def JSON_like_array(tok)
      inner = tok[1..-2]
      inner.split(/\s+/).map { |t| t =~ /\A\d+\z/ ? t.to_i : t }
    end

    def decode_stream_data(dict_src, stream_chunk)
      s_match = /\bstream\r?\n/.match(stream_chunk) or raise "stream keyword missing"
      body = stream_chunk[s_match.end(0)..]
      body = body.sub(/\bendstream\b.*/m, "")

      # Decompress if FlateDecode (handle both "/Filter /FlateDecode" and "/Filter/FlateDecode")
      data = if dict_src =~ %r{/Filter\s*/FlateDecode}
               Zlib::Inflate.inflate(body)
             else
               body
             end

      # Apply PNG predictor if present
      if dict_src =~ %r{/DecodeParms\s*<<[^>]*/Predictor\s+(\d+)}
        predictor = ::Regexp.last_match(1).to_i
        if predictor.between?(10, 15) # PNG predictors
          columns = dict_src =~ %r{/Columns\s+(\d+)} ? ::Regexp.last_match(1).to_i : 1
          data = apply_png_predictor(data, columns)
        end
      end

      data
    end

    def apply_png_predictor(data, columns)
      # PNG predictor: each row starts with a filter byte, followed by 'columns' data bytes
      row_size = columns + 1  # 1 byte for predictor + columns bytes of data
      num_rows = data.bytesize / row_size
      result = []
      prev_row = [0] * columns

      num_rows.times do |i|
        row_start = i * row_size
        filter_type = data.getbyte(row_start)
        row_bytes = (1..columns).map { |j| data.getbyte(row_start + j) }

        decoded_row = case filter_type
                      when 0  # None
                        row_bytes
                      when 1  # Sub
                        out = []
                        columns.times do |j|
                          left = j.positive? ? out[j - 1] : 0
                          out << ((row_bytes[j] + left) & 0xFF)
                        end
                        out
                      when 2  # Up
                        row_bytes.map.with_index { |b, j| (b + prev_row[j]) & 0xFF }
                      when 3  # Average
                        out = []
                        columns.times do |j|
                          left = j.positive? ? out[j - 1] : 0
                          up = prev_row[j]
                          out << ((row_bytes[j] + ((left + up) / 2)) & 0xFF)
                        end
                        out
                      when 4  # Paeth
                        out = []
                        columns.times do |j|
                          left = j.positive? ? out[j - 1] : 0
                          up = prev_row[j]
                          up_left = j.positive? ? prev_row[j - 1] : 0
                          out << ((row_bytes[j] + paeth_predictor(left, up, up_left)) & 0xFF)
                        end
                        out
                      else
                        row_bytes # Unknown filter, pass through
                      end

        result.concat(decoded_row)
        prev_row = decoded_row
      end

      result.pack("C*")
    end

    def paeth_predictor(a, b, c)
      # a = left, b = up, c = up-left
      p = a + b - c
      pa = (p - a).abs
      pb = (p - b).abs
      pc = (p - c).abs
      if pa <= pb && pa <= pc
        a
      elsif pb <= pc
        b
      else
        c
      end
    end

    def balanced_from(str, start_idx)
      depth = 0
      j = start_idx
      while j < str.length
        if str[j, 2] == "<<"
          depth += 1
          j += 2
        elsif str[j, 2] == ">>"
          depth -= 1
          j += 2
          return j if depth.zero?
        else
          j += 1
        end
      end
      raise "unterminated dict"
    end

    def find_startxref(bytes)
      if bytes =~ /startxref\s+(\d+)\s*%%EOF\s*\z/m
        return Integer(::Regexp.last_match(1))
      end

      m = bytes.rindex("startxref")
      return nil unless m

      tail = bytes[m, bytes.length - m]
      tail[/startxref\s+(\d+)/m, 1]&.to_i
    end

    def load_objstm(container_ref)
      return if @objstm_cache.key?(container_ref)

      body = object_body(container_ref)
      raise "Object stream #{container_ref.inspect} not found in xref table" unless body

      dict_start = body.index("<<") || 0
      dict_end = balanced_from(body, dict_start)
      dict_src = body[dict_start...dict_end]
      s_pos = body.index(/\bstream\r?\n/m, dict_end) or raise "objstm stream missing"
      e_pos = body.index(/\bendstream\b/m, s_pos) or raise "objstm end missing"
      data = body[s_pos..e_pos]
      raw = decode_stream_data(dict_src, data)
      n = DictScan.value_token_after("/N", dict_src).to_i
      first = DictScan.value_token_after("/First", dict_src).to_i
      parsed = AcroThat::ObjStm.parse(raw, n: n, first: first)
      @objstm_cache[container_ref] = parsed
    end
  end
end
