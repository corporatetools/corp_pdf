# frozen_string_literal: true

module AcroThat
  module Actions
    # Action to remove a field from a PDF document
    class RemoveField
      include Base

      def initialize(document, field)
        @document = document
        @field = field
      end

      def call
        af_ref = acroform_ref
        return false unless af_ref

        # Step 1: Remove widget annotations from pages' /Annots arrays
        remove_widget_annotations_from_pages

        # Step 2: Remove from /Fields array
        remove_from_fields_array(af_ref)

        # Step 3: Mark the field object as deleted by setting /T to empty
        mark_field_deleted

        true
      end

      private

      def remove_from_fields_array(af_ref)
        af_body = get_object_body_with_patch(af_ref)
        fields_array_ref = DictScan.value_token_after("/Fields", af_body)

        if fields_array_ref && fields_array_ref =~ /\A(\d+)\s+(\d+)\s+R/
          arr_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          arr_body = get_object_body_with_patch(arr_ref)
          filtered = DictScan.remove_ref_from_array(arr_body, @field.ref)
          apply_patch(arr_ref, filtered, arr_body)
        else
          filtered_af = DictScan.remove_ref_from_inline_array(af_body, "/Fields", @field.ref)
          apply_patch(af_ref, filtered_af, af_body) if filtered_af
        end
      end

      def mark_field_deleted
        fld_body = get_object_body_with_patch(@field.ref)
        return unless fld_body

        deleted_body = DictScan.replace_key_value(fld_body, "/T", "()")
        apply_patch(@field.ref, deleted_body, fld_body)
      end

      def remove_widget_annotations_from_pages
        widget_refs_to_remove = []

        field_body = get_object_body_with_patch(@field.ref)
        if field_body && DictScan.is_widget?(field_body)
          widget_refs_to_remove << @field.ref
        end

        resolver.each_object do |widget_ref, body|
          next unless body
          next if widget_ref == @field.ref
          next unless DictScan.is_widget?(body)

          body = get_object_body_with_patch(widget_ref)

          # Match by /Parent reference
          if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            if widget_parent_ref == @field.ref
              widget_refs_to_remove << widget_ref
              next
            end
          end

          # Also match by field name (/T) - some widgets might not have /Parent
          next unless body.include?("/T") && @field.name

          t_tok = DictScan.value_token_after("/T", body)
          next unless t_tok

          widget_name = DictScan.decode_pdf_string(t_tok)
          if widget_name && widget_name == @field.name
            widget_refs_to_remove << widget_ref
          end
        end

        return if widget_refs_to_remove.empty?

        widget_refs_to_remove.each do |widget_ref|
          widget_body = get_object_body_with_patch(widget_ref)

          if widget_body && widget_body =~ %r{/P\s+(\d+)\s+(\d+)\s+R}
            page_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            remove_widget_from_page_annots(page_ref, widget_ref)
          else
            find_and_remove_widget_from_all_pages(widget_ref)
          end
        end
      end

      def find_and_remove_widget_from_all_pages(widget_ref)
        # Find all page objects and check their /Annots arrays
        page_objects = []
        resolver.each_object do |ref, body|
          next unless body

          is_page = body.include?("/Type /Page") ||
                    body.include?("/Type/Page") ||
                    (body.include?("/Type") && body.include?("/Page") && body =~ %r{/Type\s*/Page})
          next unless is_page

          page_objects << ref
        end

        # Check each page's /Annots array
        page_objects.each do |page_ref|
          remove_widget_from_page_annots(page_ref, widget_ref)
        end
      end

      def remove_widget_from_page_annots(page_ref, widget_ref)
        page_body = get_object_body_with_patch(page_ref)
        return unless page_body

        # Handle inline /Annots array
        if page_body =~ %r{/Annots\s*\[(.*?)\]}m
          annots_array_str = ::Regexp.last_match(1)
          # Remove the widget reference from the array
          filtered_array = annots_array_str.gsub(/\b#{widget_ref[0]}\s+#{widget_ref[1]}\s+R\b/, "").strip
          # Clean up extra spaces
          filtered_array.gsub!(/\s+/, " ")

          new_annots = if filtered_array.empty?
                         "[]"
                       else
                         "[#{filtered_array}]"
                       end

          new_page_body = page_body.sub(%r{/Annots\s*\[.*?\]}, "/Annots #{new_annots}")
          apply_patch(page_ref, new_page_body, page_body)
        # Handle indirect /Annots array reference
        elsif page_body =~ %r{/Annots\s+(\d+)\s+(\d+)\s+R}
          annots_array_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          annots_array_body = get_object_body_with_patch(annots_array_ref)

          if annots_array_body
            filtered_body = DictScan.remove_ref_from_array(annots_array_body, widget_ref)
            apply_patch(annots_array_ref, filtered_body, annots_array_body)
          end
        end
      end
    end
  end
end
