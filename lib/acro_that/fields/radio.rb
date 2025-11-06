# frozen_string_literal: true

module AcroThat
  module Fields
    # Handles radio button field creation
    class Radio
      include Base

      attr_reader :field_obj_num

      def call
        @field_value = @field_value.to_s.gsub(" ", "")
        group_id = @options[:group_id]
        radio_groups = @document.instance_variable_get(:@radio_groups)
        parent_ref = radio_groups[group_id]

        if parent_ref
          # Subsequent radio button: add widget to existing parent's Kids array
          add_subsequent_widget(parent_ref)
        else
          # First radio button in group: create parent field and first widget
          create_first_widget(group_id, radio_groups)
        end

        true
      end

      private

      def add_subsequent_widget(parent_ref)
        widget_obj_num = next_fresh_object_number
        page_ref = find_page_ref(page_num)

        widget_body = create_widget_annotation_with_parent(widget_obj_num, parent_ref, page_ref, x, y, width,
                                                           height, @field_type, @field_value, is_radio: true)

        document.instance_variable_get(:@patches) << { ref: [widget_obj_num, 0], body: widget_body }

        add_widget_to_parent_kids(parent_ref, widget_obj_num)
        add_field_to_acroform_with_defaults(widget_obj_num)
        add_widget_to_page(widget_obj_num, page_num)

        add_radio_button_appearance(widget_obj_num, @field_value, x, y, width, height, parent_ref)

        @field_obj_num = parent_ref[0]
      end

      def create_first_widget(group_id, radio_groups)
        @field_obj_num = next_fresh_object_number
        widget_obj_num = @field_obj_num + 1

        field_body = create_field_dictionary(@field_value, @field_type)
        page_ref = find_page_ref(page_num)

        widget_body = create_widget_annotation_with_parent(widget_obj_num, [@field_obj_num, 0], page_ref, x, y, width,
                                                           height, @field_type, @field_value, is_radio: true)

        document.instance_variable_get(:@patches) << { ref: [@field_obj_num, 0], body: field_body }
        document.instance_variable_get(:@patches) << { ref: [widget_obj_num, 0], body: widget_body }

        add_widget_to_parent_kids([@field_obj_num, 0], widget_obj_num)
        add_field_to_acroform_with_defaults(@field_obj_num)
        add_field_to_acroform_with_defaults(widget_obj_num)
        add_widget_to_page(widget_obj_num, page_num)

        add_radio_button_appearance(widget_obj_num, @field_value, x, y, width, height, [@field_obj_num, 0])

        radio_groups[group_id] = [@field_obj_num, 0]
      end

      def add_radio_button_appearance(widget_obj_num, export_value, _x, _y, width, height, parent_ref = nil)
        widget_ref = [widget_obj_num, 0]
        original_widget_body = get_object_body_with_patch(widget_ref)
        return unless original_widget_body

        # Store original before modifying to avoid loading again
        widget_body = original_widget_body + ""

        # Ensure we have a valid export value - if empty, generate a unique one
        # Export value must be unique for each widget in the group for mutual exclusivity
        if export_value.nil? || export_value.to_s.empty?
          # Generate unique export value based on widget object number
          export_value = "widget_#{widget_obj_num}"
        end

        # Encode export value as PDF name (escapes special characters like parentheses)
        export_name = DictScan.encode_pdf_name(export_value)

        unchecked_obj_num = next_fresh_object_number
        unchecked_body = create_radio_unchecked_appearance(width, height)
        document.instance_variable_get(:@patches) << { ref: [unchecked_obj_num, 0], body: unchecked_body }

        checked_obj_num = next_fresh_object_number
        checked_body = create_radio_checked_appearance(width, height)
        document.instance_variable_get(:@patches) << { ref: [checked_obj_num, 0], body: checked_body }

        widget_ap_dict = "<<\n  /N <<\n    /Off #{unchecked_obj_num} 0 R\n    #{export_name} #{checked_obj_num} 0 R\n  >>\n>>"

        widget_body = if widget_body.include?("/AP")
                        DictScan.replace_key_value(widget_body, "/AP", widget_ap_dict)
                      else
                        DictScan.upsert_key_value(widget_body, "/AP", widget_ap_dict)
                      end

        # Determine if this button should be selected by default
        # Only set selected if the selected option is explicitly set to true
        should_be_selected = [true, "true"].include?(@options[:selected])

        as_value = should_be_selected ? export_name : "/Off"
        widget_body = if widget_body.include?("/AS")
                        DictScan.replace_key_value(widget_body, "/AS", as_value)
                      else
                        DictScan.upsert_key_value(widget_body, "/AS", as_value)
                      end

        # Use stored original_widget_body instead of loading again
        apply_patch(widget_ref, widget_body, original_widget_body)

        # Track original_parent_body outside blocks so we can reuse it
        original_parent_body = nil

        # Update parent field's /V if this button is selected by default
        if parent_ref && should_be_selected
          original_parent_body = get_object_body_with_patch(parent_ref)
          if original_parent_body
            # Store original before modifying
            parent_body = original_parent_body + ""
            # Update parent's /V to match the selected button's export value
            parent_body = if parent_body.include?("/V")
                            DictScan.replace_key_value(parent_body, "/V", export_name)
                          else
                            DictScan.upsert_key_value(parent_body, "/V", export_name)
                          end
            # Use stored original_parent_body instead of loading again
            apply_patch(parent_ref, parent_body, original_parent_body)
          end
        end

        # Update parent field's /AP if parent_ref is provided
        if parent_ref
          # Reuse original_parent_body if we already loaded it, otherwise load it
          original_parent_body_for_ap = original_parent_body || get_object_body_with_patch(parent_ref)
          return unless original_parent_body_for_ap

          # Use a working copy for modification
          parent_body_for_ap = original_parent_body_for_ap + ""
          parent_ap_tok = DictScan.value_token_after("/AP", parent_body_for_ap)
          if parent_ap_tok && parent_ap_tok.start_with?("<<")
            n_tok = DictScan.value_token_after("/N", parent_ap_tok)
            if n_tok && n_tok.start_with?("<<") && !n_tok.include?(export_name.to_s)
              new_n_tok = n_tok.chomp(">>") + "  #{export_name} #{checked_obj_num} 0 R\n>>"
              new_ap_tok = parent_ap_tok.sub(n_tok) { |_| new_n_tok }
              new_parent_body = parent_body_for_ap.sub(parent_ap_tok) { |_| new_ap_tok }
              apply_patch(parent_ref, new_parent_body, original_parent_body_for_ap)
            end
          else
            ap_dict = "<<\n  /N <<\n    #{export_name} #{checked_obj_num} 0 R\n    /Off #{unchecked_obj_num} 0 R\n  >>\n>>"
            new_parent_body = DictScan.upsert_key_value(parent_body_for_ap, "/AP", ap_dict)
            apply_patch(parent_ref, new_parent_body, original_parent_body_for_ap)
          end
        end
      end

      def create_radio_checked_appearance(width, height)
        # Draw only the checkmark (no border)
        border_width = [width * 0.08, height * 0.08].min

        check_x1 = width * 0.25
        check_y1 = height * 0.45
        check_x2 = width * 0.45
        check_y2 = height * 0.25
        check_x3 = width * 0.75
        check_y3 = height * 0.75

        content_stream = "q\n"
        # Draw checkmark only (no border)
        content_stream += "0 0 0 rg\n" # Black fill color
        content_stream += "#{border_width} w\n" # Line width for checkmark
        content_stream += "#{check_x1} #{check_y1} m\n"
        content_stream += "#{check_x2} #{check_y2} l\n"
        content_stream += "#{check_x3} #{check_y3} l\n"
        content_stream += "S\n" # Stroke the checkmark
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end

      def create_radio_unchecked_appearance(width, height)
        # Empty appearance (no border, no checkmark)
        content_stream = "q\n"
        # Empty appearance for unchecked state
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end
    end
  end
end
