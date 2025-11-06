# frozen_string_literal: true

module AcroThat
  module Fields
    # Handles text field creation
    class Text
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

        true
      end
    end
  end
end
