# frozen_string_literal: true

module AcroThat
  module Fields
    # Handles checkbox field creation
    class Checkbox
      include Base

      attr_reader :field_obj_num

      def call
        @field_obj_num = next_fresh_object_number
        widget_obj_num = @field_obj_num + 1

        field_body = create_field_dictionary(@field_value, @field_type)
        page_ref = find_page_ref(page_num)

        widget_body = create_widget_annotation_with_parent(widget_obj_num, [@field_obj_num, 0], page_ref, x, y, width,
                                                           height, @field_type, @field_value)

        document.instance_variable_get(:@patches) << { ref: [@field_obj_num, 0], body: field_body }
        document.instance_variable_get(:@patches) << { ref: [widget_obj_num, 0], body: widget_body }

        add_field_to_acroform_with_defaults(@field_obj_num)
        add_widget_to_page(widget_obj_num, page_num)

        add_checkbox_appearance(widget_obj_num)

        true
      end

      private

      def add_checkbox_appearance(widget_obj_num)
        yes_obj_num = next_fresh_object_number
        off_obj_num = yes_obj_num + 1

        yes_body = create_checkbox_yes_appearance(width, height)
        document.instance_variable_get(:@patches) << { ref: [yes_obj_num, 0], body: yes_body }

        off_body = create_checkbox_off_appearance(width, height)
        document.instance_variable_get(:@patches) << { ref: [off_obj_num, 0], body: off_body }

        widget_ref = [widget_obj_num, 0]
        original_widget_body = get_object_body_with_patch(widget_ref)
        # Use +"" instead of dup to create a mutable copy without keeping reference to original
        widget_body = original_widget_body + ""

        ap_dict = "<<\n  /N <<\n    /Yes #{yes_obj_num} 0 R\n    /Off #{off_obj_num} 0 R\n  >>\n>>"

        widget_body = if widget_body.include?("/AP")
                        DictScan.replace_key_value(widget_body, "/AP", ap_dict)
                      else
                        DictScan.upsert_key_value(widget_body, "/AP", ap_dict)
                      end

        value_str = @field_value.to_s
        is_checked = value_str == "Yes" || value_str == "/Yes" || value_str == "true" || @field_value == true
        normalized_value = is_checked ? "Yes" : "Off"

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
        border_width = [width * 0.08, height * 0.08].min
        line_width = [width * 0.05, height * 0.05].min

        check_x1 = width * 0.25
        check_y1 = height * 0.45
        check_x2 = width * 0.45
        check_y2 = height * 0.25
        check_x3 = width * 0.75
        check_y3 = height * 0.75

        content_stream = "q\n"
        # Draw square border around field bounds
        content_stream += "0 0 0 RG\n" # Black stroke color
        content_stream += "#{line_width} w\n" # Line width
        # Draw rectangle from (0,0) to (width, height)
        content_stream += "0 0 m\n"
        content_stream += "#{width} 0 l\n"
        content_stream += "#{width} #{height} l\n"
        content_stream += "0 #{height} l\n"
        content_stream += "0 0 l\n"
        content_stream += "S\n" # Stroke the border

        # Draw checkmark
        content_stream += "0 0 0 rg\n" # Black fill color
        content_stream += "#{border_width} w\n" # Line width for checkmark
        content_stream += "#{check_x1} #{check_y1} m\n"
        content_stream += "#{check_x2} #{check_y2} l\n"
        content_stream += "#{check_x3} #{check_y3} l\n"
        content_stream += "S\n" # Stroke the checkmark
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end

      def create_checkbox_off_appearance(width, height)
        line_width = [width * 0.05, height * 0.05].min

        content_stream = "q\n"
        # Draw square border around field bounds
        content_stream += "0 0 0 RG\n" # Black stroke color
        content_stream += "#{line_width} w\n" # Line width
        # Draw rectangle from (0,0) to (width, height)
        content_stream += "0 0 m\n"
        content_stream += "#{width} 0 l\n"
        content_stream += "#{width} #{height} l\n"
        content_stream += "0 #{height} l\n"
        content_stream += "0 0 l\n"
        content_stream += "S\n" # Stroke the border
        content_stream += "Q\n"

        build_form_xobject(content_stream, width, height)
      end
    end
  end
end
