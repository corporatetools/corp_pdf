# frozen_string_literal: true

module AcroThat
  module DictScan
    module_function

    # --- low-level string helpers -------------------------------------------------

    def strip_stream_bodies(pdf)
      pdf.gsub(/stream\r?\n.*?endstream/mi) { "stream\nENDSTREAM_STRIPPED\nendstream" }
    end

    def each_dictionary(str)
      i = 0
      while (open = str.index("<<", i))
        depth = 0
        j = open
        found = nil
        while j < str.length
          if str[j, 2] == "<<"
            depth += 1
            j += 2
          elsif str[j, 2] == ">>"
            depth -= 1
            j += 2
            if depth.zero?
              found = str[open...j]
              break
            end
          else
            j += 1
          end
        end
        break unless found

        yield found
        i = j
      end
    end

    def unescape_literal(s)
      out = +""
      i = 0
      while i < s.length
        ch = s[i]
        if ch == "\\"
          i += 1
          break if i >= s.length

          esc = s[i]
          case esc
          when "n" then out << "\n"
          when "r" then out << "\r"
          when "t" then out << "\t"
          when "b" then out << "\b"
          when "f" then out << "\f"
          when "\\", "(", ")" then out << esc
          when /\d/
            oct = esc
            if i + 1 < s.length && s[i + 1] =~ /\d/
              i += 1
              oct << s[i]
              if i + 1 < s.length && s[i + 1] =~ /\d/
                i += 1
                oct << s[i]
              end
            end
            out << oct.to_i(8).chr
          else
            out << esc
          end
        else
          out << ch
        end
        i += 1
      end
      out
    end

    def decode_pdf_string(token)
      return nil unless token

      t = token.strip

      # Literal string: ( ... ) with PDF escapes and optional UTF-16BE BOM
      if t.start_with?("(") && t.end_with?(")")
        inner = t[1..-2]
        s = unescape_literal(inner)
        if s.bytesize >= 2 && s.getbyte(0) == 0xFE && s.getbyte(1) == 0xFF
          return s.byteslice(2, s.bytesize - 2).force_encoding("UTF-16BE").encode("UTF-8")
        else
          return s.b
                  .force_encoding("binary")
                  .encode("UTF-8", invalid: :replace, undef: :replace)
        end
      end

      # Hex string: < ... > with optional UTF-16BE BOM
      if t.start_with?("<") && t.end_with?(">")
        hex = t[1..-2].gsub(/\s+/, "")
        hex << "0" if hex.length.odd?
        bytes = [hex].pack("H*")
        if bytes.bytesize >= 2 && bytes.getbyte(0) == 0xFE && bytes.getbyte(1) == 0xFF
          return bytes.byteslice(2, bytes.bytesize - 2).force_encoding("UTF-16BE").encode("UTF-8")
        else
          return bytes.force_encoding("binary").encode("UTF-8", invalid: :replace, undef: :replace)
        end
      end

      # Fallback: return token as-is (names, numbers, refs, etc.)
      t
    end

    def encode_pdf_string(val)
      case val
      when true then "true"
      when false then "false"
      when Symbol
        "/#{val}"
      when String
        if val.ascii_only?
          "(#{val.gsub(/([\\()])/, '\\\\\\1').gsub("\n", '\\n')})"
        else
          utf16 = val.encode("UTF-16BE")
          bytes = "\xFE\xFF#{utf16}"
          "<#{bytes.unpack1('H*')}>"
        end
      else
        val.to_s
      end
    end

    def value_token_after(key, dict_src)
      # Find key followed by delimiter (whitespace, (, <, [, /)
      # Use regex to ensure key is a complete token
      match = dict_src.match(%r{#{Regexp.escape(key)}(?=[\s(<\[/])})
      return nil unless match

      i = match.end(0)
      i += 1 while i < dict_src.length && dict_src[i] =~ /\s/
      return nil if i >= dict_src.length

      case dict_src[i]
      when "("
        depth = 0
        j = i
        while j < dict_src.length
          ch = dict_src[j]
          if ch == "\\"
            j += 2
            next
          end
          depth += 1 if ch == "("
          if ch == ")"
            depth -= 1
            if depth.zero?
              j += 1
              return dict_src[i...j]
            end
          end
          j += 1
        end
        nil
      when "<"
        if dict_src[i, 2] == "<<"
          "<<"
        else
          j = dict_src.index(">", i)
          j ? dict_src[i..j] : nil
        end
      when "["
        # Array token - find matching closing bracket
        depth = 0
        j = i
        while j < dict_src.length
          ch = dict_src[j]
          if ch == "["
            depth += 1
          elsif ch == "]"
            depth -= 1
            if depth.zero?
              j += 1
              return dict_src[i...j]
            end
          end
          j += 1
        end
        nil
      when "/"
        # PDF name token - extract until whitespace or delimiter
        j = i
        while j < dict_src.length
          ch = dict_src[j]
          # PDF names can contain most characters except NUL, whitespace, and delimiters
          break if ch =~ /[\s<>\[\]()]/ || (ch == "/" && j > i)

          j += 1
        end
        j > i ? dict_src[i...j] : nil
      else
        # atom
        m = %r{\A([^\s<>\[\]()/%]+)}.match(dict_src[i..])
        m ? m[1] : nil
      end
    end

    def replace_key_value(dict_src, key, new_token)
      # Replace existing key's value token in a single dictionary source string (<<...>>)
      # Use precise position-based replacement to avoid any regex issues

      # Find the key position using pattern matching
      key_pattern = %r{#{Regexp.escape(key)}(?=[\s(<\[/])}
      key_match = dict_src.match(key_pattern)
      return upsert_key_value(dict_src, key, new_token) unless key_match

      # Get the existing value token
      tok = value_token_after(key, dict_src)
      return upsert_key_value(dict_src, key, new_token) unless tok

      # Find exact positions
      key_match.begin(0)
      key_end = key_match.end(0)

      # Skip whitespace after key
      value_start = key_end
      value_start += 1 while value_start < dict_src.length && dict_src[value_start] =~ /\s/

      # Verify the token matches at this position
      unless value_start < dict_src.length && dict_src[value_start, tok.length] == tok
        # Token doesn't match - fallback to upsert
        return upsert_key_value(dict_src, key, new_token)
      end

      # Replace using precise string slicing - this preserves everything exactly
      before = dict_src[0...value_start]
      after = dict_src[(value_start + tok.length)..]
      result = "#{before}#{new_token}#{after}"

      # Verify the result still has valid dictionary structure
      unless result.include?("<<") && result.include?(">>")
        # Dictionary corrupted - return original
        return dict_src
      end

      result
    end

    def upsert_key_value(dict_src, key, token)
      # Insert right after '<<' with a space between key and value
      dict_src.sub("<<") { |_| "<<#{key} #{token}" }
    end

    def appearance_choice_for(new_value, dict_src)
      # If /AP << /N << /Yes ... /Off ... >> >> exists, return /Yes or /Off
      return nil unless dict_src.include?("/AP")

      # Simplistic detection
      yes = dict_src.include?("/Yes")
      off = dict_src.include?("/Off")
      case new_value
      when true, :Yes, "Yes" then yes ? "/Yes" : nil
      when false, :Off, "Off" then off ? "/Off" : nil
      end
    end

    def remove_ref_from_array(array_body, ref)
      num, gen = ref
      array_body.gsub(/\b#{num}\s+#{gen}\s+R\b/, "").gsub(/\[\s+/, "[").gsub(/\s+\]/, "]")
    end

    def add_ref_to_array(array_body, ref)
      num, gen = ref
      ref_token = "#{num} #{gen} R"

      # Handle empty array
      if array_body.strip == "[]"
        return "[#{ref_token}]"
      end

      # Add before the closing bracket, with proper spacing
      # Find the last ']' and insert before it
      if array_body.strip.end_with?("]")
        # Remove trailing ] and add ref, then add ] back
        without_closing = array_body.rstrip.chomp("]")
        return "#{without_closing} #{ref_token}]"
      end

      # Fallback: just append
      "#{array_body} #{ref_token}"
    end

    def remove_ref_from_inline_array(dict_body, key, ref)
      return nil unless dict_body.include?(key)

      # Extract the inline array token after key, then rebuild
      arr_tok = value_token_after(key, dict_body)
      return nil unless arr_tok && arr_tok.start_with?("[")

      dict_body.sub(arr_tok) { |t| remove_ref_from_array(t, ref) }
    end

    def add_ref_to_inline_array(dict_body, key, ref)
      return nil unless dict_body.include?(key)

      # Extract the inline array token after key, then rebuild
      arr_tok = value_token_after(key, dict_body)
      return nil unless arr_tok && arr_tok.start_with?("[")

      new_arr_tok = add_ref_to_array(arr_tok, ref)
      dict_body.sub(arr_tok) { |_| new_arr_tok }
    end

    def is_widget?(body)
      return false unless body

      body.include?("/Subtype") && body.include?("/Widget") && body =~ %r{/Subtype\s*/Widget}
    end

    # Check if a field is multiline by checking /Ff flag bit 12 (0x1000)
    def is_multiline_field?(dict_body)
      return false unless dict_body

      ff_tok = value_token_after("/Ff", dict_body)
      return false unless ff_tok

      ff_value = ff_tok.to_i
      # Bit 12 (0x1000) indicates multiline text field
      ff_value.anybits?(0x1000)
    end

    # Remove /AP (appearance stream) entry from a dictionary
    def remove_appearance_stream(dict_body)
      return dict_body unless dict_body&.include?("/AP")

      # Find /AP entry using pattern matching
      ap_key_pattern = %r{/AP(?=[\s(<\[/])}
      ap_match = dict_body.match(ap_key_pattern)
      return dict_body unless ap_match

      key_end = ap_match.end(0)
      value_start = key_end
      value_start += 1 while value_start < dict_body.length && dict_body[value_start] =~ /\s/
      return dict_body if value_start >= dict_body.length

      # Determine what type of value we have
      first_char = dict_body[value_start]
      value_end = value_start

      if first_char == "<" && value_start + 1 < dict_body.length && dict_body[value_start + 1] == "<"
        # Inline dictionary: /AP << ... >>
        # Need to find matching closing >>
        depth = 0
        i = value_start
        while i < dict_body.length
          if dict_body[i, 2] == "<<"
            depth += 1
            i += 2
          elsif dict_body[i, 2] == ">>"
            depth -= 1
            i += 2
            if depth.zero?
              value_end = i
              break
            end
          else
            i += 1
          end
        end
      elsif ["(", "<", "["].include?(first_char)
        # Use value_token_after to get the complete token
        ap_tok = value_token_after("/AP", dict_body)
        return dict_body unless ap_tok

        value_end = value_start + ap_tok.length
      else
        # Reference or other simple token
        ap_tok = value_token_after("/AP", dict_body)
        return dict_body unless ap_tok

        value_end = value_start + ap_tok.length
      end

      # Skip trailing whitespace after the value
      value_end += 1 while value_end < dict_body.length && dict_body[value_end] =~ /\s/

      # Find the start of /AP (may need to remove preceding space/newline)
      removal_start = ap_match.begin(0)

      # Try to remove preceding whitespace/newline if it's on its own line
      if removal_start.positive? && dict_body[removal_start - 1] == "\n"
        # Check if there's whitespace before the newline we should remove too
        line_start = removal_start - 1
        line_start -= 1 while line_start.positive? && dict_body[line_start - 1] =~ /\s/
        # Only remove the line if it starts with whitespace (indentation)
        if line_start.positive? && dict_body[line_start - 1] == "\n"
          removal_start = line_start
        end
      end

      # Build result without /AP entry
      before = dict_body[0...removal_start]
      after = dict_body[value_end..]
      result = "#{before}#{after}"

      # Verify the result still has valid dictionary structure
      unless result.include?("<<") && result.include?(">>")
        return dict_body # Return original if corrupted
      end

      result
    end
  end
end
