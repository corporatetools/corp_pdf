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
        fld = @document.list_fields.find { |f| f.name == @name }
        return false unless fld

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

        # Encode the new value
        v_token = DictScan.encode_pdf_string(new_value)

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
        ft_pattern = %r{/FT\s+/Btn}
        if ft_pattern.match(patched) && (as_needed = DictScan.appearance_choice_for(new_value, patched))
          as_pattern = %r{/AS(?=[\s(<\[/])}
          has_as = patched.match(as_pattern)

          patched = if has_as
                      DictScan.replace_key_value(patched, "/AS", as_needed)
                    else
                      DictScan.upsert_key_value(patched, "/AS", as_needed)
                    end

          # Verify /AS replacement worked
          unless patched && patched.include?("<<") && patched.include?(">>")
            warn "Warning: Dictionary corrupted after /AS replacement"
            # Revert to before /AS change
            return DictScan.replace_key_value(dict_body, "/V", v_token) if has_v

            return dict_body
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
        return if acro_body.include?("/NeedAppearances")

        acro_patched = DictScan.upsert_key_value(acro_body, "/NeedAppearances", "true")
        apply_patch(af_ref, acro_patched, acro_body)
      end

      def check_if_multiline_field(field_ref)
        field_body = get_object_body_with_patch(field_ref)
        return false unless field_body

        DictScan.is_multiline_field?(field_body)
      end
    end
  end
end
