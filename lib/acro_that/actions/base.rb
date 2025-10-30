# frozen_string_literal: true

module AcroThat
  module Actions
    module Base
      def resolver
        @document.instance_variable_get(:@resolver)
      end

      def patches
        @document.instance_variable_get(:@patches)
      end

      def get_object_body_with_patch(ref)
        body = resolver.object_body(ref)
        existing_patch = patches.find { |p| p[:ref] == ref }
        existing_patch ? existing_patch[:body] : body
      end

      def apply_patch(ref, body, original_body = nil)
        original_body ||= resolver.object_body(ref)
        return if body == original_body

        patches.reject! { |p| p[:ref] == ref }
        patches << { ref: ref, body: body }
      end

      def next_fresh_object_number
        max_obj_num = 0
        resolver.each_object do |ref, _|
          max_obj_num = [max_obj_num, ref[0]].max
        end
        patches.each do |p|
          max_obj_num = [max_obj_num, p[:ref][0]].max
        end
        max_obj_num + 1
      end

      def acroform_ref
        @document.send(:acroform_ref)
      end
    end
  end
end

