# frozen_string_literal: true

module AcroThat
  module Actions
    # Action to add a new field to a PDF document
    class AddField
      include Base

      attr_reader :field_obj_num, :field_type, :field_value

      def initialize(document, name, options = {})
        @document = document
        @name = name
        @options = options
      end

      def call
        x = @options[:x] || 100
        y = @options[:y] || 500
        width = @options[:width] || 100
        height = @options[:height] || 20
        page_num = @options[:page] || 1

        # Normalize field type: accept symbols or strings, convert to PDF format
        type_input = @options[:type] || "/Tx"
        @field_type = case type_input
                      when :text, "text", "/Tx", "/tx"
                        "/Tx"
                      when :button, "button", "/Btn", "/btn"
                        "/Btn"
                      when :choice, "choice", "/Ch", "/ch"
                        "/Ch"
                      when :signature, "signature", "/Sig", "/sig"
                        "/Sig"
                      else
                        type_input.to_s # Use as-is if it's already in PDF format
                      end
        @field_value = @options[:value] || ""

        # Create a proper field dictionary + a widget annotation that references it via /Parent
        @field_obj_num = next_fresh_object_number
        widget_obj_num = @field_obj_num + 1

        field_body = create_field_dictionary(@field_value, @field_type)

        # Find the page ref for /P on widget (must happen before we create patches)
        page_ref = find_page_ref(page_num)

        # Create widget with page reference
        widget_body = create_widget_annotation_with_parent(widget_obj_num, [@field_obj_num, 0], page_ref, x, y, width,
                                                           height, @field_type, @field_value)

        # Queue objects
        @document.instance_variable_get(:@patches) << { ref: [@field_obj_num, 0], body: field_body }
        @document.instance_variable_get(:@patches) << { ref: [widget_obj_num, 0], body: widget_body }

        # Add field reference (not widget) to AcroForm /Fields AND ensure defaults in ONE patch
        add_field_to_acroform_with_defaults(@field_obj_num)

        # Add widget to the target page's /Annots
        add_widget_to_page(widget_obj_num, page_num)

        true
      end

      private

      def create_field_dictionary(value, type)
        dict = "<<\n"
        dict += "  /FT #{type}\n"
        dict += "  /T #{DictScan.encode_pdf_string(@name)}\n"
        dict += "  /Ff 0\n"
        dict += "  /DA (/Helv 0 Tf 0 g)\n"
        dict += "  /V #{DictScan.encode_pdf_string(value)}\n" if value && !value.empty?
        dict += ">>"
        dict
      end

      def create_widget_annotation_with_parent(_widget_obj_num, parent_ref, page_ref, x, y, width, height, type, value)
        rect_array = "[#{x} #{y} #{x + width} #{y + height}]"
        widget = "<<\n"
        widget += "  /Type /Annot\n"
        widget += "  /Subtype /Widget\n"
        widget += "  /Parent #{parent_ref[0]} #{parent_ref[1]} R\n"
        widget += "  /P #{page_ref[0]} #{page_ref[1]} R\n" if page_ref
        widget += "  /FT #{type}\n"
        widget += "  /Rect #{rect_array}\n"
        widget += "  /F 4\n"
        widget += "  /DA (/Helv 0 Tf 0 g)\n"
        widget += "  /V #{DictScan.encode_pdf_string(value)}\n" if value && !value.empty?
        widget += ">>"
        widget
      end

      def add_field_to_acroform_with_defaults(field_obj_num)
        af_ref = acroform_ref
        return false unless af_ref

        af_body = get_object_body_with_patch(af_ref)

        patched = af_body.dup

        # Step 1: Add field to /Fields array
        fields_array_ref = DictScan.value_token_after("/Fields", patched)

        if fields_array_ref && fields_array_ref =~ /\A(\d+)\s+(\d+)\s+R/
          # Reference case: /Fields points to a separate array object
          arr_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          arr_body = get_object_body_with_patch(arr_ref)
          new_body = DictScan.add_ref_to_array(arr_body, [field_obj_num, 0])
          apply_patch(arr_ref, new_body, arr_body)
        elsif patched.include?("/Fields")
          # Inline array case: use DictScan utility
          patched = DictScan.add_ref_to_inline_array(patched, "/Fields", [field_obj_num, 0])
        else
          # No /Fields exists - add it with the field reference
          patched = DictScan.upsert_key_value(patched, "/Fields", "[#{field_obj_num} 0 R]")
        end

        # Step 2: Ensure /NeedAppearances true
        unless patched.include?("/NeedAppearances")
          patched = DictScan.upsert_key_value(patched, "/NeedAppearances", "true")
        end

        # Step 3: Ensure /DR /Font has /Helv mapping
        unless patched.include?("/DR") && patched.include?("/Helv")
          font_obj_num = next_fresh_object_number
          font_body = "<<\n  /Type /Font\n  /Subtype /Type1\n  /BaseFont /Helvetica\n>>"
          patches << { ref: [font_obj_num, 0], body: font_body }

          if patched.include?("/DR")
            # /DR exists - try to add /Font if it doesn't exist
            dr_tok = DictScan.value_token_after("/DR", patched)
            if dr_tok && dr_tok.start_with?("<<")
              # Check if /Font already exists in /DR
              unless dr_tok.include?("/Font")
                # Add /Font to existing /DR dictionary
                new_dr_tok = dr_tok.chomp(">>") + "  /Font << /Helv #{font_obj_num} 0 R >>\n>>"
                patched = patched.sub(dr_tok) { |_| new_dr_tok }
              end
            else
              # /DR exists but isn't a dictionary - replace it
              patched = DictScan.replace_key_value(patched, "/DR", "<< /Font << /Helv #{font_obj_num} 0 R >> >>")
            end
          else
            # No /DR exists - add it
            patched = DictScan.upsert_key_value(patched, "/DR", "<< /Font << /Helv #{font_obj_num} 0 R >> >>")
          end
        end

        apply_patch(af_ref, patched, af_body)
        true
      end

      def find_page_ref(page_num)
        page_objects = []
        resolver.each_object do |ref, body|
          next unless body

          # Check for /Type /Page (actual page, not /Type/Pages)
          # Must match /Type /Page or /Type/Page but NOT /Type/Pages
          is_page = (body.include?("/Type /Page") ||
                    (body =~ %r{/Type\s*/Page(?!s)\b}))
          next unless is_page

          page_objects << ref
        end

        # If still no pages found, try to find them via the page tree
        if page_objects.empty?
          # Find the document catalog's /Pages entry
          root_ref = resolver.root_ref
          if root_ref
            catalog_body = resolver.object_body(root_ref)
            if catalog_body && catalog_body =~ %r{/Pages\s+(\d+)\s+(\d+)\s+R}
              pages_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
              pages_body = resolver.object_body(pages_ref)

              # Extract /Kids array from Pages object
              if pages_body && pages_body =~ %r{/Kids\s*\[(.*?)\]}m
                kids_array = ::Regexp.last_match(1)
                # Extract all object references from Kids array
                kids_array.scan(/(\d+)\s+(\d+)\s+R/) do |num_str, gen_str|
                  kid_ref = [num_str.to_i, gen_str.to_i]
                  kid_body = resolver.object_body(kid_ref)
                  # Check if this kid is a page (not /Type/Pages)
                  if kid_body && (kid_body.include?("/Type /Page") || kid_body =~ %r{/Type\s*/Page(?!s)\b})
                    page_objects << kid_ref
                  elsif kid_body && kid_body.include?("/Type /Pages")
                    # Recursively find pages in this Pages node
                    if kid_body =~ %r{/Kids\s*\[(.*?)\]}m
                      kid_body[::Regexp.last_match(0)..].scan(/(\d+)\s+(\d+)\s+R/) do |n, g|
                        grandkid_ref = [n.to_i, g.to_i]
                        grandkid_body = resolver.object_body(grandkid_ref)
                        if grandkid_body && (grandkid_body.include?("/Type /Page") || grandkid_body =~ %r{/Type\s*/Page(?!s)\b})
                          page_objects << grandkid_ref
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        return page_objects[0] if page_objects.empty?
        return page_objects[page_num - 1] if page_num.positive? && page_num <= page_objects.length

        page_objects[0]
      end

      def add_widget_to_page(widget_obj_num, page_num)
        # Find the specific page using the same logic as find_page_ref
        target_page_ref = find_page_ref(page_num)
        return false unless target_page_ref

        page_body = get_object_body_with_patch(target_page_ref)

        # Use DictScan utility to safely add reference to /Annots array
        new_body = if page_body =~ %r{/Annots\s*\[(.*?)\]}m
                     # Inline array - add to it
                     result = DictScan.add_ref_to_inline_array(page_body, "/Annots", [widget_obj_num, 0])
                     if result && result != page_body
                       result
                     else
                       # Fallback: use string manipulation
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
                     # Indirect array reference - need to read and modify the array object
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

                       # Page body doesn't need to change (still references the same array object)
                       page_body
                     else
                       # Array object not found - fallback to creating inline array
                       page_body.sub(%r{/Annots\s+\d+\s+\d+\s+R}, "/Annots [#{ref_token}]")
                     end
                   else
                     # No /Annots exists - add it with the widget reference
                     # Insert /Annots before the closing >> of the dictionary
                     ref_token = "#{widget_obj_num} 0 R"
                     if page_body.include?(">>")
                       # Find the last >> (closing the outermost dictionary) and insert /Annots before it
                       page_body.reverse.sub(">>".reverse, "/Annots [#{ref_token}]>>".reverse).reverse
                     else
                       page_body + " /Annots [#{ref_token}]"
                     end
                   end

        apply_patch(target_page_ref, new_body, page_body) if new_body && new_body != page_body
        true
      end
    end
  end
end
