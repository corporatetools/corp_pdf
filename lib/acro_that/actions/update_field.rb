# frozen_string_literal: true

module AcroThat
  module Actions
    # Action to update a field's value and optionally rename it in a PDF document
    class UpdateField
      include Base

      def initialize(document, name, new_value, new_name: nil)
        @document = document
        @name = name
        @new_value = new_value
        @new_name = new_name
      end

      def call
        # First try to find in list_fields (already written fields)
        fld = @document.list_fields.find { |f| f.name == @name }

        # If not found, check if field was just added (in patches) and create a Field object for it
        unless fld
          patches = @document.instance_variable_get(:@patches)
          field_patch = patches.find do |p|
            next unless p[:body]
            next unless p[:body].include?("/T")

            t_tok = DictScan.value_token_after("/T", p[:body])
            next unless t_tok

            field_name = DictScan.decode_pdf_string(t_tok)
            field_name == @name
          end

          if field_patch && field_patch[:body].include?("/FT")
            ft_tok = DictScan.value_token_after("/FT", field_patch[:body])
            if ft_tok
              # Create a temporary Field object for newly added field
              position = {}
              fld = Field.new(@name, nil, ft_tok, field_patch[:ref], @document, position)
            end
          end
        end

        return false unless fld

        # Check if this is a signature field and if new_value looks like image data
        if fld.signature_field?
          # Check if new_value looks like base64 image data or data URI
          image_data = @new_value
          if image_data && image_data.is_a?(String) && (image_data.start_with?("data:image/") || (image_data.length > 50 && image_data.match?(%r{^[A-Za-z0-9+/]*={0,2}$})))
            # Try adding signature appearance using Signature field class
            result = AcroThat::Fields::Signature.add_appearance(@document, fld.ref, image_data)
            return result if result
            # If appearance fails, fall through to normal update
          end
        end

        original = get_object_body_with_patch(fld.ref)
        return false unless original

        # Determine if this is a widget annotation or field object
        is_widget = original.include?("/Subtype /Widget")
        field_ref = fld.ref # Default: the ref we found is the field

        # If this is a widget, we need to also update the parent field object (if it exists)
        # Otherwise, this widget IS the field (flat structure)
        if is_widget
          parent_tok = DictScan.value_token_after("/Parent", original)
          if parent_tok && parent_tok =~ /\A(\d+)\s+(\d+)\s+R/
            field_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            field_body = get_object_body_with_patch(field_ref)
            if field_body && !field_body.include?("/Subtype /Widget")
              new_field_body = patch_field_value_body(field_body, @new_value)

              # Check if multiline and remove appearance stream from parent field too
              is_multiline = DictScan.is_multiline_field?(field_body) || DictScan.is_multiline_field?(new_field_body)
              if is_multiline
                new_field_body = DictScan.remove_appearance_stream(new_field_body)
              end

              if new_field_body && new_field_body.include?("<<") && new_field_body.include?(">>")
                apply_patch(field_ref, new_field_body, field_body)
              end
            end
          end
        end

        # Update the object we found (widget or field) - always update what we found
        new_body = patch_field_value_body(original, @new_value)

        # Check if this is a multiline field - if so, remove appearance stream
        # macOS Preview needs appearance streams to be regenerated for multiline fields
        is_multiline = check_if_multiline_field(field_ref)
        if is_multiline
          new_body = DictScan.remove_appearance_stream(new_body)
        end

        # Update field name (/T) if requested
        if @new_name && !@new_name.empty?
          new_body = patch_field_name_body(new_body, @new_name)
        end

        # Validate the patched body is valid before adding to patches
        unless new_body && new_body.include?("<<") && new_body.include?(">>")
          warn "Warning: Invalid patched body for #{fld.ref.inspect}, skipping update"
          return false
        end

        apply_patch(fld.ref, new_body, original)

        # If we renamed the field, also update the parent field object and all widgets
        if @new_name && !@new_name.empty?
          # Update parent field object if it exists (separate from widget)
          if field_ref != fld.ref
            field_body = get_object_body_with_patch(field_ref)
            if field_body && !field_body.include?("/Subtype /Widget")
              new_field_body = patch_field_name_body(field_body, @new_name)
              if new_field_body && new_field_body.include?("<<") && new_field_body.include?(">>")
                apply_patch(field_ref, new_field_body, field_body)
              end
            end
          end

          # Update all widget annotations that reference this field
          update_widget_names_for_field(field_ref, @new_name)
        end

        # Also update any widget annotations that reference this field via /Parent
        update_widget_annotations_for_field(field_ref, @new_value)

        # If this is a checkbox without appearance streams, create them
        if fld.button_field?
          # Check if it's a checkbox (not a radio button) by checking field flags
          field_body = get_object_body_with_patch(field_ref)
          is_radio = false
          if field_body
            field_flags_match = field_body.match(%r{/Ff\s+(\d+)})
            if field_flags_match
              field_flags = field_flags_match[1].to_i
              # Radio button flag is bit 15 = 32768
              is_radio = field_flags.anybits?(32_768)
            end
          end

          if is_radio
            # For radio buttons, update all widget appearances (overwrite existing)
            update_radio_button_appearances(field_ref)
          else
            # For checkboxes, create/update appearance
            widget_ref = find_checkbox_widget(fld.ref)
            if widget_ref
              widget_body = get_object_body_with_patch(widget_ref)
              # Create appearances if /AP doesn't exist, or overwrite if it does
              rect = extract_widget_rect(widget_body)
              if rect && rect[:width].positive? && rect[:height].positive?
                add_checkbox_appearance(widget_ref, rect[:width], rect[:height])
              end
            end
          end
        end

        # Best-effort: set NeedAppearances to true so viewers regenerate appearances
        ensure_need_appearances

        true
      end

      private

      def patch_field_value_body(dict_body, new_value)
        # Simple, reliable approach: Use DictScan methods that preserve structure
        # Don't manipulate the dictionary body - let DictScan handle it

        # Ensure we have a valid dictionary
        return dict_body unless dict_body&.include?("<<")

        # For checkboxes (/Btn fields), normalize value to "Yes" or "Off"
        ft_pattern = %r{/FT\s+/Btn}
        is_button_field = ft_pattern.match(dict_body)

        normalized_value = if is_button_field
                             # For checkboxes/radio buttons, normalize to "Yes" or "Off"
                             # Accept "Yes", "/Yes" (PDF name format), true (boolean), or "true" (string)
                             value_str = new_value.to_s
                             is_checked = ["Yes", "/Yes", "true"].include?(value_str) || new_value == true
                             is_checked ? "Yes" : "Off"
                           else
                             new_value
                           end

        # Encode the normalized value
        v_token = DictScan.encode_pdf_string(normalized_value)

        # Find /V using pattern matching to ensure we get the complete key
        v_key_pattern = %r{/V(?=[\s(<\[/])}
        has_v = dict_body.match(v_key_pattern)

        # Update /V - use replace_key_value which handles the replacement carefully
        patched = if has_v
                    DictScan.replace_key_value(dict_body, "/V", v_token)
                  else
                    DictScan.upsert_key_value(dict_body, "/V", v_token)
                  end

        # Verify replacement worked and dictionary is still valid
        unless patched && patched.include?("<<") && patched.include?(">>")
          warn "Warning: Dictionary corrupted after /V replacement"
          return dict_body # Return original if corrupted
        end

        # Update /AS for checkboxes/radio buttons if needed
        # Check for /FT /Btn more carefully
        if ft_pattern.match(patched)
          # For button fields, set /AS based on normalized value
          as_value = if normalized_value == "Yes"
                       "/Yes"
                     else
                       "/Off"
                     end

          # Only set /AS if /AP exists (appearance dictionary is present)
          # If /AP doesn't exist, we can't set /AS properly
          if patched.include?("/AP")
            as_pattern = %r{/AS(?=[\s(<\[/])}
            has_as = patched.match(as_pattern)

            patched = if has_as
                        DictScan.replace_key_value(patched, "/AS", as_value)
                      else
                        DictScan.upsert_key_value(patched, "/AS", as_value)
                      end

            # Verify /AS replacement worked
            unless patched && patched.include?("<<") && patched.include?(">>")
              warn "Warning: Dictionary corrupted after /AS replacement"
              # Revert to before /AS change
              return DictScan.replace_key_value(dict_body, "/V", v_token) if has_v

              return dict_body
            end
          end
        end

        patched
      end

      def patch_field_name_body(dict_body, new_name)
        # Ensure we have a valid dictionary
        return dict_body unless dict_body&.include?("<<")

        # Encode the new name
        t_token = DictScan.encode_pdf_string(new_name)

        # Find /T using pattern matching
        t_key_pattern = %r{/T(?=[\s(<\[/])}
        has_t = dict_body.match(t_key_pattern)

        # Update /T - use replace_key_value which handles the replacement carefully
        patched = if has_t
                    DictScan.replace_key_value(dict_body, "/T", t_token)
                  else
                    DictScan.upsert_key_value(dict_body, "/T", t_token)
                  end

        # Verify replacement worked and dictionary is still valid
        unless patched && patched.include?("<<") && patched.include?(">>")
          warn "Warning: Dictionary corrupted after /T replacement"
          return dict_body # Return original if corrupted
        end

        patched
      end

      def update_widget_annotations_for_field(field_ref, new_value)
        # Check if the field is multiline by looking at the field object
        field_body = get_object_body_with_patch(field_ref)
        is_multiline = field_body && DictScan.is_multiline_field?(field_body)

        resolver.each_object do |ref, body|
          next unless body
          next unless DictScan.is_widget?(body)
          next unless body.include?("/Parent")

          body = get_object_body_with_patch(ref)

          parent_tok = DictScan.value_token_after("/Parent", body)
          next unless parent_tok && parent_tok =~ /\A(\d+)\s+(\d+)\s+R/

          widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          next unless widget_parent_ref == field_ref

          widget_body_patched = patch_field_value_body(body, new_value)

          # For multiline fields, remove appearance stream from widgets too
          if is_multiline
            widget_body_patched = DictScan.remove_appearance_stream(widget_body_patched)
          end

          apply_patch(ref, widget_body_patched, body)
        end
      end

      def update_widget_names_for_field(field_ref, new_name)
        resolver.each_object do |ref, body|
          next unless body
          next unless DictScan.is_widget?(body)

          body = get_object_body_with_patch(ref)

          # Match widgets by /Parent reference
          if body.include?("/Parent")
            parent_tok = DictScan.value_token_after("/Parent", body)
            if parent_tok && parent_tok =~ /\A(\d+)\s+(\d+)\s+R/
              widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
              if widget_parent_ref == field_ref
                widget_body_patched = patch_field_name_body(body, new_name)
                apply_patch(ref, widget_body_patched, body)
              end
            end
          end

          # Also match widgets by field name (/T) - some widgets might not have /Parent
          next unless body.include?("/T")

          t_tok = DictScan.value_token_after("/T", body)
          next unless t_tok

          widget_name = DictScan.decode_pdf_string(t_tok)
          if widget_name && widget_name == @name
            widget_body_patched = patch_field_name_body(body, new_name)
            apply_patch(ref, widget_body_patched, body)
          end
        end
      end

      def ensure_need_appearances
        af_ref = acroform_ref
        return unless af_ref

        acro_body = get_object_body_with_patch(af_ref)
        # Set /NeedAppearances false to use our custom appearance streams
        # If we set it to true, viewers will ignore our custom appearances and generate defaults
        # (e.g., circular radio buttons instead of our square checkboxes)
        acro_patched = if acro_body.include?("/NeedAppearances")
                         DictScan.replace_key_value(acro_body, "/NeedAppearances", "false")
                       else
                         DictScan.upsert_key_value(acro_body, "/NeedAppearances", "false")
                       end
        apply_patch(af_ref, acro_patched, acro_body)
      end

      def check_if_multiline_field(field_ref)
        field_body = get_object_body_with_patch(field_ref)
        return false unless field_body

        DictScan.is_multiline_field?(field_body)
      end

      def find_checkbox_widget(field_ref)
        # Check patches first
        patches = @document.instance_variable_get(:@patches)
        patches.each do |patch|
          next unless patch[:body]
          next unless DictScan.is_widget?(patch[:body])

          # Check if widget has /Parent pointing to field_ref
          if patch[:body] =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            return patch[:ref] if parent_ref == field_ref
          end

          # Also check if widget IS the field (flat structure)
          if patch[:body].include?("/FT") && DictScan.value_token_after("/FT",
                                                                        patch[:body]) == "/Btn" && (patch[:ref] == field_ref)
            return patch[:ref]
          end
        end

        # Then check resolver (for existing widgets)
        resolver.each_object do |ref, body|
          next unless body && DictScan.is_widget?(body)

          # Check if widget has /Parent pointing to field_ref
          if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            return ref if parent_ref == field_ref
          end

          # Also check if widget IS the field (flat structure)
          if body.include?("/FT") && DictScan.value_token_after("/FT", body) == "/Btn" && (ref == field_ref)
            return ref
          end
        end

        # Fallback: if field_ref itself is a widget
        body = get_object_body_with_patch(field_ref)
        return field_ref if body && DictScan.is_widget?(body) && body.include?("/FT") && DictScan.value_token_after(
          "/FT", body
        ) == "/Btn"

        nil
      end

      def update_radio_button_appearances(parent_ref)
        # Find all widgets that are children of this parent field
        widgets = []

        # Check patches first
        patches = @document.instance_variable_get(:@patches)
        patches.each do |patch|
          next unless patch[:body]
          next unless DictScan.is_widget?(patch[:body])

          next unless patch[:body] =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}

          widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          if widget_parent_ref == parent_ref
            widgets << patch[:ref]
          end
        end

        # Also check resolver (for existing widgets)
        resolver.each_object do |ref, body|
          next unless body && DictScan.is_widget?(body)

          next unless body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}

          widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          if (widget_parent_ref == parent_ref) && !widgets.include?(ref)
            widgets << ref
          end
        end

        # Update appearance for each widget using Radio class method
        widgets.each do |widget_ref|
          widget_body = get_object_body_with_patch(widget_ref)
          next unless widget_body

          # Get widget dimensions
          rect = extract_widget_rect(widget_body)
          next unless rect && rect[:width].positive? && rect[:height].positive?

          # Get export value from widget's /AP /N dictionary
          export_value = nil
          if widget_body.include?("/AP")
            ap_tok = DictScan.value_token_after("/AP", widget_body)
            if ap_tok && ap_tok.start_with?("<<")
              n_tok = DictScan.value_token_after("/N", ap_tok)
              if n_tok && n_tok.start_with?("<<")
                # Extract export value (not /Off)
                export_values = n_tok.scan(%r{/([^\s<>\[\]]+)\s+\d+\s+\d+\s+R}).flatten.reject { |v| v == "Off" }
                export_value = export_values.first if export_values.any?
              end
            end
          end

          # If no export value found, generate one
          export_value ||= "widget_#{widget_ref[0]}"

          # Create a Radio instance to reuse appearance creation logic
          radio_handler = AcroThat::Fields::Radio.new(@document, "", { width: rect[:width], height: rect[:height] })
          radio_handler.send(
            :add_radio_button_appearance,
            widget_ref[0],
            export_value,
            0, 0, # x, y not needed when overwriting
            rect[:width],
            rect[:height],
            parent_ref
          )
        end
      end

      def extract_widget_rect(widget_body)
        return nil unless widget_body

        rect_tok = DictScan.value_token_after("/Rect", widget_body)
        return nil unless rect_tok&.start_with?("[")

        rect_values = rect_tok.scan(/[-+]?\d*\.?\d+/).map(&:to_f)
        return nil unless rect_values.length == 4

        x1, y1, x2, y2 = rect_values
        width = (x2 - x1).abs
        height = (y2 - y1).abs

        return nil if width <= 0 || height <= 0

        { x: x1, y: y1, width: width, height: height }
      end

      def add_checkbox_appearance(widget_ref, width, height)
        # Create appearance form XObjects for Yes and Off states
        yes_obj_num = next_fresh_object_number
        off_obj_num = yes_obj_num + 1

        # Create Yes appearance (checked box with checkmark)
        yes_body = create_checkbox_yes_appearance(width, height)
        @document.instance_variable_get(:@patches) << { ref: [yes_obj_num, 0], body: yes_body }

        # Create Off appearance (empty box)
        off_body = create_checkbox_off_appearance(width, height)
        @document.instance_variable_get(:@patches) << { ref: [off_obj_num, 0], body: off_body }

        # Get current widget body and add /AP dictionary
        original_widget_body = get_object_body_with_patch(widget_ref)
        widget_body = original_widget_body.dup

        # Create /AP dictionary with Yes and Off appearances
        ap_dict = "<<\n  /N <<\n    /Yes #{yes_obj_num} 0 R\n    /Off #{off_obj_num} 0 R\n  >>\n>>"

        # Add /AP to widget
        if widget_body.include?("/AP")
          # Replace existing /AP
          ap_key_pattern = %r{/AP(?=[\s(<\[/])}
          if widget_body.match(ap_key_pattern)
            widget_body = DictScan.replace_key_value(widget_body, "/AP", ap_dict)
          end
        else
          # Insert /AP before closing >>
          widget_body = DictScan.upsert_key_value(widget_body, "/AP", ap_dict)
        end

        # Set /AS based on the value - use the EXACT same normalization logic as widget creation
        # This ensures consistency between /V and /AS
        # Normalize value: "Yes" if truthy (Yes, "/Yes", true, etc.), otherwise "Off"
        value_str = @new_value.to_s
        is_checked = value_str == "Yes" || value_str == "/Yes" || value_str == "true" || @new_value == true
        normalized_value = is_checked ? "Yes" : "Off"

        # Set /AS to match normalized value (same as what was set for /V in widget creation)
        as_value = if normalized_value == "Yes"
                     "/Yes"
                   else
                     "/Off"
                   end

        widget_body = if widget_body.include?("/AS")
                        DictScan.replace_key_value(widget_body, "/AS", as_value)
                      else
                        DictScan.upsert_key_value(widget_body, "/AS", as_value)
                      end

        apply_patch(widget_ref, widget_body, original_widget_body)
      end

      def create_checkbox_yes_appearance(width, height)
        # Create a form XObject that draws a checked checkbox
        # Box outline + checkmark
        # Scale to match width and height
        # Simple appearance: draw a box and a checkmark
        # For simplicity, use PDF drawing operators
        # Box: rectangle from (0,0) to (width, height)
        # Checkmark: simple path drawing

        # PDF content stream for checked checkbox
        # Draw just the checkmark (no box border)
        border_width = [width * 0.08, height * 0.08].min

        # Calculate checkmark path
        check_x1 = width * 0.25
        check_y1 = height * 0.45
        check_x2 = width * 0.45
        check_y2 = height * 0.25
        check_x3 = width * 0.75
        check_y3 = height * 0.75

        content_stream = "q\n"
        content_stream += "0 0 0 rg\n" # Black color (darker)
        content_stream += "#{border_width} w\n" # Line width
        # Draw checkmark only (no box border)
        content_stream += "#{check_x1} #{check_y1} m\n"
        content_stream += "#{check_x2} #{check_y2} l\n"
        content_stream += "#{check_x3} #{check_y3} l\n"
        content_stream += "S\n" # Stroke
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end

      def create_checkbox_off_appearance(width, height)
        # Create a form XObject for unchecked checkbox
        # Empty appearance (no border, no checkmark) - viewer will draw default checkbox

        content_stream = "q\n"
        # Empty appearance for unchecked state
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end

      def build_form_xobject(content_stream, width, height)
        # Build a Form XObject dictionary with the given content stream
        dict = "<<\n"
        dict += "  /Type /XObject\n"
        dict += "  /Subtype /Form\n"
        dict += "  /BBox [0 0 #{width} #{height}]\n"
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
