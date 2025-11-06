# frozen_string_literal: true

module AcroThat
  module Fields
    # Base class for field types with shared functionality
    module Base
      include Actions::Base

      attr_reader :document, :name, :options, :metadata, :field_type, :field_value

      def initialize(document, name, options = {})
        @document = document
        @name = name
        @options = normalize_hash_keys(options)
        @metadata = normalize_hash_keys(@options[:metadata] || {})
        @field_type = determine_field_type
        @field_value = @options[:value] || ""
      end

      def x
        @options[:x] || 100
      end

      def y
        @options[:y] || 500
      end

      def width
        @options[:width] || 100
      end

      def height
        @options[:height] || 20
      end

      def page_num
        @options[:page] || 1
      end

      private

      def normalize_hash_keys(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), normalized|
          sym_key = key.is_a?(Symbol) ? key : key.to_sym
          normalized[sym_key] = value.is_a?(Hash) ? normalize_hash_keys(value) : value
        end
      end

      def determine_field_type
        type_input = @options[:type] || "/Tx"
        case type_input
        when :text, "text", "/Tx", "/tx"
          "/Tx"
        when :button, "button", "/Btn", "/btn"
          "/Btn"
        when :radio, "radio"
          "/Btn"
        when :checkbox, "checkbox"
          "/Btn"
        when :choice, "choice", "/Ch", "/ch"
          "/Ch"
        when :signature, "signature", "/Sig", "/sig"
          "/Sig"
        else
          type_input.to_s
        end
      end

      def create_field_dictionary(value, type)
        dict = "<<\n"
        dict += "  /FT #{type}\n"
        dict += "  /T #{DictScan.encode_pdf_string(@name)}\n"

        # Apply /Ff from metadata, or use default 0
        field_flags = @metadata[:Ff] || 0
        dict += "  /Ff #{field_flags}\n"

        dict += "  /DA (/Helv 0 Tf 0 g)\n"

        # Check if this is a radio button (has Radio flag set)
        is_radio_field = field_flags.anybits?(32_768)

        # For signature fields with image data, don't set /V (appearance stream will be added separately)
        # For radio buttons, /V should be the export value name (e.g., "/email", "/phone")
        # For checkboxes, set /V to normalized value (Yes/Off)
        # For other fields, set /V normally
        should_set_value = if type == "/Sig" && value && !value.empty?
                             !(value.is_a?(String) && (value.start_with?("data:image/") || (value.length > 50 && value.match?(%r{^[A-Za-z0-9+/]*={0,2}$}))))
                           else
                             true
                           end

        # For radio buttons: use export value as PDF name (e.g., "/email")
        # For checkboxes: normalize to "Yes" or "Off"
        # For other fields: use value as-is
        normalized_field_value = if is_radio_field && value && !value.to_s.empty?
                                   # Encode export value as PDF name (escapes special characters like parentheses)
                                   DictScan.encode_pdf_name(value)
                                 elsif type == "/Btn" && value
                                   value_str = value.to_s
                                   is_checked = ["Yes", "/Yes", "true"].include?(value_str) || value == true
                                   is_checked ? "Yes" : "Off"
                                 else
                                   value
                                 end

        # For radio buttons, /V should only be set if explicitly selected
        # For other fields, encode as PDF string
        if should_set_value && normalized_field_value && !normalized_field_value.to_s.empty?
          # For radio buttons, only set /V if selected option is explicitly set to true
          if is_radio_field
            # Only set /V for radio buttons if selected option is true
            if [true, "true"].include?(@options[:selected]) && normalized_field_value.to_s.start_with?("/")
              dict += "  /V #{normalized_field_value}\n"
            end
          else
            dict += "  /V #{DictScan.encode_pdf_string(normalized_field_value)}\n"
          end
        end

        # Apply other metadata entries (excluding Ff which we handled above)
        @metadata.each do |key, val|
          next if key == :Ff

          pdf_key = DictScan.format_pdf_key(key)
          pdf_value = DictScan.format_pdf_value(val)
          dict += "  #{pdf_key} #{pdf_value}\n"
        end

        dict += ">>"
        dict
      end

      def create_widget_annotation_with_parent(_widget_obj_num, parent_ref, page_ref, x, y, width, height, type, value,
                                               is_radio: false)
        rect_array = "[#{x} #{y} #{x + width} #{y + height}]"
        widget = "<<\n"
        widget += "  /Type /Annot\n"
        widget += "  /Subtype /Widget\n"
        widget += "  /Parent #{parent_ref[0]} #{parent_ref[1]} R\n"
        widget += "  /P #{page_ref[0]} #{page_ref[1]} R\n" if page_ref

        widget += "  /FT #{type}\n"
        if is_radio
          widget += "  /T #{DictScan.encode_pdf_string(@name)}\n"
        else

          should_set_value = if type == "/Sig" && value && !value.empty?
                               !(value.is_a?(String) && (value.start_with?("data:image/") || (value.length > 50 && value.match?(%r{^[A-Za-z0-9+/]*={0,2}$}))))
                             elsif type == "/Btn"
                               true
                             else
                               true
                             end

          if type == "/Btn" && should_set_value
            value_str = value.to_s
            is_checked = ["Yes", "/Yes", "true"].include?(value_str) || value == true
            checkbox_value = is_checked ? "Yes" : "Off"
            widget += "  /V #{DictScan.encode_pdf_string(checkbox_value)}\n"
          elsif should_set_value && value && !value.empty?
            widget += "  /V #{DictScan.encode_pdf_string(value)}\n"
          end
        end

        widget += "  /Rect #{rect_array}\n"
        widget += "  /F 4\n"

        widget += if is_radio
                    "  /MK << /BC [0.0] /BG [1.0] >>\n"
                  else
                    "  /DA (/Helv 0 Tf 0 g)\n"
                  end

        @metadata.each do |key, val|
          pdf_key = DictScan.format_pdf_key(key)
          pdf_value = DictScan.format_pdf_value(val)
          next if ["/F", "/V"].include?(pdf_key)
          next if is_radio && ["/Ff", "/DA"].include?(pdf_key)

          widget += "  #{pdf_key} #{pdf_value}\n"
        end

        widget += ">>"
        widget
      end

      def add_field_to_acroform_with_defaults(field_obj_num)
        af_ref = acroform_ref
        return false unless af_ref

        af_body = get_object_body_with_patch(af_ref)
        # Use +"" instead of dup to create a mutable copy without keeping reference to original
        patched = af_body + ""

        # Step 1: Add field to /Fields array
        fields_array_ref = DictScan.value_token_after("/Fields", patched)

        if fields_array_ref && fields_array_ref =~ /\A(\d+)\s+(\d+)\s+R/
          arr_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          arr_body = get_object_body_with_patch(arr_ref)
          new_body = DictScan.add_ref_to_array(arr_body, [field_obj_num, 0])
          apply_patch(arr_ref, new_body, arr_body)
        elsif patched.include?("/Fields")
          patched = DictScan.add_ref_to_inline_array(patched, "/Fields", [field_obj_num, 0])
        else
          patched = DictScan.upsert_key_value(patched, "/Fields", "[#{field_obj_num} 0 R]")
        end

        # Step 2: Ensure /NeedAppearances false (we provide custom appearance streams)
        # Setting to false tells viewers to use our custom appearances instead of generating defaults
        # If we don't set this or set it to true, viewers will ignore our custom appearances and
        # generate their own default appearances (e.g., circular radio buttons instead of our squares)
        patched = if patched.include?("/NeedAppearances")
                    # Replace existing /NeedAppearances with false
                    DictScan.replace_key_value(patched, "/NeedAppearances", "false")
                  else
                    DictScan.upsert_key_value(patched, "/NeedAppearances", "false")
                  end

        # Step 2.5: Remove /XFA if present
        if patched.include?("/XFA")
          xfa_pattern = %r{/XFA(?=[\s(<\[/])}
          if patched.match(xfa_pattern)
            xfa_value = DictScan.value_token_after("/XFA", patched)
            if xfa_value
              xfa_match = patched.match(xfa_pattern)
              if xfa_match
                key_start = xfa_match.begin(0)
                value_start = xfa_match.end(0)
                value_start += 1 while value_start < patched.length && patched[value_start] =~ /\s/
                value_end = value_start + xfa_value.length
                value_end += 1 while value_end < patched.length && patched[value_end] =~ /\s/
                before = patched[0...key_start]
                before = before.rstrip
                after = patched[value_end..]
                patched = "#{before} #{after.lstrip}".strip
                patched = patched.gsub(/\s+/, " ")
              end
            end
          end
        end

        # Step 3: Ensure /DR /Font has /Helv mapping
        unless patched.include?("/DR") && patched.include?("/Helv")
          font_obj_num = next_fresh_object_number
          font_body = "<<\n  /Type /Font\n  /Subtype /Type1\n  /BaseFont /Helvetica\n>>"
          document.instance_variable_get(:@patches) << { ref: [font_obj_num, 0], body: font_body }

          if patched.include?("/DR")
            dr_tok = DictScan.value_token_after("/DR", patched)
            if dr_tok && dr_tok.start_with?("<<")
              unless dr_tok.include?("/Font")
                new_dr_tok = dr_tok.chomp(">>") + "  /Font << /Helv #{font_obj_num} 0 R >>\n>>"
                patched = patched.sub(dr_tok) { |_| new_dr_tok }
              end
            else
              patched = DictScan.replace_key_value(patched, "/DR", "<< /Font << /Helv #{font_obj_num} 0 R >> >>")
            end
          else
            patched = DictScan.upsert_key_value(patched, "/DR", "<< /Font << /Helv #{font_obj_num} 0 R >> >>")
          end
        end

        apply_patch(af_ref, patched, af_body)
        true
      end

      def find_page_ref(page_num)
        find_page_by_number(page_num)
      end

      def add_widget_to_page(widget_obj_num, page_num)
        target_page_ref = find_page_ref(page_num)
        return false unless target_page_ref

        page_body = get_object_body_with_patch(target_page_ref)

        new_body = if page_body =~ %r{/Annots\s*\[(.*?)\]}m
                     result = DictScan.add_ref_to_inline_array(page_body, "/Annots", [widget_obj_num, 0])
                     if result && result != page_body
                       result
                     else
                       annots_array = ::Regexp.last_match(1)
                       ref_token = "#{widget_obj_num} 0 R"
                       new_annots = if annots_array.strip.empty?
                                      "[#{ref_token}]"
                                    else
                                      "[#{annots_array} #{ref_token}]"
                                    end
                       page_body.sub(%r{/Annots\s*\[.*?\]}, "/Annots #{new_annots}")
                     end
                   elsif page_body =~ %r{/Annots\s+(\d+)\s+(\d+)\s+R}
                     annots_array_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
                     annots_array_body = get_object_body_with_patch(annots_array_ref)

                     ref_token = "#{widget_obj_num} 0 R"
                     if annots_array_body
                       new_annots_body = if annots_array_body.strip == "[]"
                                           "[#{ref_token}]"
                                         elsif annots_array_body.strip.start_with?("[") && annots_array_body.strip.end_with?("]")
                                           without_brackets = annots_array_body.strip[1..-2].strip
                                           "[#{without_brackets} #{ref_token}]"
                                         else
                                           "[#{annots_array_body} #{ref_token}]"
                                         end

                       apply_patch(annots_array_ref, new_annots_body, annots_array_body)
                       page_body
                     else
                       page_body.sub(%r{/Annots\s+\d+\s+\d+\s+R}, "/Annots [#{ref_token}]")
                     end
                   else
                     ref_token = "#{widget_obj_num} 0 R"
                     if page_body.include?(">>")
                       page_body.reverse.sub(">>".reverse, "/Annots [#{ref_token}]>>".reverse).reverse
                     else
                       page_body + " /Annots [#{ref_token}]"
                     end
                   end

        apply_patch(target_page_ref, new_body, page_body) if new_body && new_body != page_body
        true
      end

      def add_widget_to_parent_kids(parent_ref, widget_obj_num)
        parent_body = get_object_body_with_patch(parent_ref)
        return unless parent_body

        kids_array_ref = DictScan.value_token_after("/Kids", parent_body)

        if kids_array_ref && kids_array_ref =~ /\A(\d+)\s+(\d+)\s+R\z/
          arr_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          arr_body = get_object_body_with_patch(arr_ref)
          new_body = DictScan.add_ref_to_array(arr_body, [widget_obj_num, 0])
          apply_patch(arr_ref, new_body, arr_body)
        elsif kids_array_ref && kids_array_ref.start_with?("[")
          new_body = DictScan.add_ref_to_inline_array(parent_body, "/Kids", [widget_obj_num, 0])
          apply_patch(parent_ref, new_body, parent_body) if new_body && new_body != parent_body
        else
          new_body = DictScan.upsert_key_value(parent_body, "/Kids", "[#{widget_obj_num} 0 R]")
          apply_patch(parent_ref, new_body, parent_body) if new_body && new_body != parent_body
        end
      end

      def build_form_xobject(content_stream, width, height)
        dict = "<<\n"
        dict += "  /Type /XObject\n"
        dict += "  /Subtype /Form\n"
        dict += "  /BBox [0 0 #{width} #{height}]\n"
        dict += "  /Matrix [1 0 0 1 0 0]\n"
        dict += "  /Resources << >>\n"
        dict += "  /Length #{content_stream.bytesize}\n"
        dict += ">>\n"
        dict += "stream\n"
        dict += content_stream
        dict += "\nendstream"

        dict
      end
    end
  end
end
