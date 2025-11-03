# frozen_string_literal: true

module AcroThat
  class Document
    attr_reader :path

    # Flatten a PDF to remove incremental updates
    def self.flatten_pdf(input_path, output_path = nil)
      output = new(input_path).flatten

      if output_path
        File.binwrite(output_path, output)
        return output_path
      else
        return new(StringIO.new(output))
      end
    end

    def initialize(path_or_io)
      @path = path_or_io.is_a?(String) ? path_or_io : nil
      @raw = case path_or_io
             when String then File.binread(path_or_io)
             else path_or_io.binmode
                  path_or_io.read
             end.freeze
      @resolver = AcroThat::ObjectResolver.new(@raw)
      @patches = []
    end

    # Flatten this document to remove incremental updates
    def flatten
      root_ref = @resolver.root_ref
      raise "Cannot flatten: no /Root found" unless root_ref

      objects = []
      @resolver.each_object do |ref, body|
        objects << { ref: ref, body: body } if body
      end

      objects.sort_by! { |obj| obj[:ref][0] }

      writer = PDFWriter.new
      writer.write_header

      objects.each do |obj|
        writer.write_object(obj[:ref], obj[:body])
      end

      writer.write_xref

      trailer_dict = @resolver.trailer_dict
      info_ref = nil
      if trailer_dict =~ %r{/Info\s+(\d+)\s+(\d+)\s+R}
        info_ref = [::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i]
      end

      # Write trailer
      max_obj_num = objects.map { |obj| obj[:ref][0] }.max || 0
      writer.write_trailer(max_obj_num + 1, root_ref, info_ref)

      writer.output
    end

    # Flatten this document in-place (mutates current instance)
    def flatten!
      flattened_content = flatten.freeze
      @raw = flattened_content
      @resolver.clear_cache
      @resolver = AcroThat::ObjectResolver.new(flattened_content)
      @patches = []

      self
    end

    # Return an array of page information (page number, width, height, ref, metadata)
    def list_pages
      pages = []
      page_objects = find_all_pages

      # Second pass: extract information from each page
      page_objects.each_with_index do |ref, index|
        body = @resolver.object_body(ref)
        next unless body

        # Extract MediaBox, CropBox, or ArtBox for dimensions
        width = nil
        height = nil

        # Try MediaBox first (most common) - also extract width/height
        media_box = DictScan.parse_box(body, "MediaBox")
        if media_box
          width = media_box[:urx] - media_box[:llx]
          height = media_box[:ury] - media_box[:lly]
        end

        # Parse other box types
        crop_box = DictScan.parse_box(body, "CropBox")
        art_box = DictScan.parse_box(body, "ArtBox")
        bleed_box = DictScan.parse_box(body, "BleedBox")
        trim_box = DictScan.parse_box(body, "TrimBox")

        # Extract rotation
        rotate = nil
        if body =~ %r{/Rotate\s+(\d+)}
          rotate = Integer(::Regexp.last_match(1))
        end

        # Extract Resources reference
        resources_ref = nil
        if body =~ %r{/Resources\s+(\d+)\s+(\d+)\s+R}
          resources_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
        end

        # Extract Parent reference
        parent_ref = nil
        if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
          parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
        end

        # Extract Contents reference(s)
        contents_refs = []
        if body =~ %r{/Contents\s+(\d+)\s+(\d+)\s+R}
          contents_refs << [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
        elsif body =~ %r{/Contents\s*\[(.*?)\]}
          contents_array = ::Regexp.last_match(1)
          contents_array.scan(/(\d+)\s+(\d+)\s+R/) do |num_str, gen_str|
            contents_refs << [num_str.to_i, gen_str.to_i]
          end
        end

        # Build metadata hash
        metadata = {
          rotate: rotate,
          media_box: media_box,
          crop_box: crop_box,
          art_box: art_box,
          bleed_box: bleed_box,
          trim_box: trim_box,
          resources_ref: resources_ref,
          parent_ref: parent_ref,
          contents_refs: contents_refs
        }

        pages << Page.new(
          index + 1, # Page number starting at 1
          width,
          height,
          ref,
          metadata,
          self # Pass document reference
        )
      end

      pages
    end

    # Return an array of Field(name, value, type, ref)
    def list_fields
      fields = []
      field_widgets = {}
      widgets_by_name = {}

      # First pass: collect widget information
      @resolver.each_object do |ref, body|
        next unless body

        is_widget = DictScan.is_widget?(body)

        # Collect widget information if this is a widget
        if is_widget
          # Extract position from widget
          rect_tok = DictScan.value_token_after("/Rect", body)
          if rect_tok && rect_tok.start_with?("[")
            # Parse [x y x+width y+height] format
            rect_values = rect_tok.scan(/[-+]?\d*\.?\d+/).map(&:to_f)
            if rect_values.length == 4
              x, y, x2, y2 = rect_values
              width = x2 - x
              height = y2 - y

              page_num = nil
              if body =~ %r{/P\s+(\d+)\s+(\d+)\s+R}
                page_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
                page_num = find_page_number_for_ref(page_ref)
              end

              widget_info = {
                x: x, y: y, width: width, height: height, page: page_num
              }

              if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
                parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]

                field_widgets[parent_ref] ||= []
                field_widgets[parent_ref] << widget_info
              end

              if body.include?("/T")
                t_tok = DictScan.value_token_after("/T", body)
                if t_tok
                  widget_name = DictScan.decode_pdf_string(t_tok)
                  if widget_name && !widget_name.empty?
                    widgets_by_name[widget_name] ||= []
                    widgets_by_name[widget_name] << widget_info
                  end
                end
              end
            end
          end
        end

        # Second pass: collect all fields (both field objects and widget annotations with /T)
        next unless body.include?("/T")

        is_widget_field = is_widget
        hint = body.include?("/FT") || is_widget_field || body.include?("/Kids") || body.include?("/Parent")
        next unless hint

        t_tok = DictScan.value_token_after("/T", body)
        next unless t_tok

        name = DictScan.decode_pdf_string(t_tok)
        next if name.nil? || name.empty? # Skip fields with empty names (deleted fields)

        v_tok = body.include?("/V") ? DictScan.value_token_after("/V", body) : nil
        value = v_tok && v_tok != "<<" ? DictScan.decode_pdf_string(v_tok) : nil

        ft_tok = body.include?("/FT") ? DictScan.value_token_after("/FT", body) : nil
        type = ft_tok

        # Normalize button field values: "Yes" -> "/Yes" to match PDF name conventions
        if type == "/Btn" && value == "Yes"
          value = "/Yes"
        end

        position = {}
        if is_widget
          rect_tok = DictScan.value_token_after("/Rect", body)
          if rect_tok && rect_tok.start_with?("[")
            rect_values = rect_tok.scan(/[-+]?\d*\.?\d+/).map(&:to_f)
            if rect_values.length == 4
              x, y, x2, y2 = rect_values
              position = { x: x, y: y, width: x2 - x, height: y2 - y }

              if body =~ %r{/P\s+(\d+)\s+(\d+)\s+R}
                page_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
                position[:page] = find_page_number_for_ref(page_ref)
              end
            end
          end
        elsif field_widgets[ref]
          widget_info = field_widgets[ref].first
          position = {
            x: widget_info[:x],
            y: widget_info[:y],
            width: widget_info[:width],
            height: widget_info[:height],
            page: widget_info[:page]
          }
        elsif widgets_by_name[name]
          widget_info = widgets_by_name[name].first
          position = {
            x: widget_info[:x],
            y: widget_info[:y],
            width: widget_info[:width],
            height: widget_info[:height],
            page: widget_info[:page]
          }
        end

        fields << Field.new(name, value, type, ref, self, position)
      end

      if fields.empty?
        stripped = DictScan.strip_stream_bodies(@raw)
        DictScan.each_dictionary(stripped) do |dict_src|
          next unless dict_src.include?("/T")

          is_widget_field_fallback = DictScan.is_widget?(dict_src)
          hint = dict_src.include?("/FT") || is_widget_field_fallback || dict_src.include?("/Kids") || dict_src.include?("/Parent")
          next unless hint

          t_tok = DictScan.value_token_after("/T", dict_src)
          next unless t_tok

          name = DictScan.decode_pdf_string(t_tok)
          next if name.nil? || name.empty? # Skip fields with empty names (deleted fields)

          v_tok = dict_src.include?("/V") ? DictScan.value_token_after("/V", dict_src) : nil
          value = v_tok && v_tok != "<<" ? DictScan.decode_pdf_string(v_tok) : nil
          ft_tok = dict_src.include?("/FT") ? DictScan.value_token_after("/FT", dict_src) : nil
          fields << Field.new(name, value, ft_tok, [-1, 0], self)
        end
      end

      fields.group_by(&:name).values.map { |arr| arr.min_by { |f| f.ref[0] } }
    end

    # Add a new field to the AcroForm /Fields array
    def add_field(name, options = {})
      action = Actions::AddField.new(self, name, options)
      result = action.call

      if result
        position = {
          x: options[:x] || 100,
          y: options[:y] || 500,
          width: options[:width] || 100,
          height: options[:height] || 20,
          page: options[:page] || 1
        }

        field_obj_num = action.field_obj_num
        field_type = action.field_type
        field_value = action.field_value

        Field.new(name, field_value, field_type, [field_obj_num, 0], self, position)
      end
    end

    # Update field by name, setting /V and optionally /AS on widgets
    def update_field(name, new_value, new_name: nil)
      # First try to find in list_fields (already written fields)
      field = list_fields.find { |f| f.name == name }

      # If not found, check if field was just added (in patches) and create a Field object for it
      unless field
        patches = @patches
        field_patch = patches.find do |p|
          next unless p[:body]
          next unless p[:body].include?("/T")

          t_tok = DictScan.value_token_after("/T", p[:body])
          next unless t_tok

          field_name = DictScan.decode_pdf_string(t_tok)
          field_name == name
        end

        if field_patch && field_patch[:body].include?("/FT")
          ft_tok = DictScan.value_token_after("/FT", field_patch[:body])
          if ft_tok
            # Create a temporary Field object for newly added field
            position = {}
            field = Field.new(name, nil, ft_tok, field_patch[:ref], self, position)
          end
        end
      end

      return false unless field

      field.update(new_value, new_name: new_name)
    end

    # Remove field by name from the AcroForm /Fields array
    def remove_field(fld)
      field = fld.is_a?(Field) ? fld : list_fields.find { |f| f.name == fld }
      return false unless field

      field.remove
    end

    # Clean up the PDF by removing unwanted fields.
    # Options:
    #   - keep_fields: Array of field names to keep (all others removed)
    #   - remove_fields: Array of field names to remove
    #   - remove_pattern: Regex pattern - fields matching this are removed
    #   - block: Given field name, return true to keep, false to remove
    # This rewrites the entire PDF (like flatten) but excludes the unwanted fields.
    def clear(keep_fields: nil, remove_fields: nil, remove_pattern: nil)
      root_ref = @resolver.root_ref
      raise "Cannot clear: no /Root found" unless root_ref

      # Build a set of fields to remove
      fields_to_remove = Set.new

      # Get all current fields
      all_fields = list_fields

      if block_given?
        # Use block to determine which fields to keep
        all_fields.each do |field|
          fields_to_remove.add(field.name) unless yield(field.name)
        end
      elsif keep_fields
        # Keep only specified fields
        keep_set = Set.new(keep_fields.map(&:to_s))
        all_fields.each do |field|
          fields_to_remove.add(field.name) unless keep_set.include?(field.name)
        end
      elsif remove_fields
        # Remove specified fields
        remove_set = Set.new(remove_fields.map(&:to_s))
        all_fields.each do |field|
          fields_to_remove.add(field.name) if remove_set.include?(field.name)
        end
      elsif remove_pattern
        # Remove fields matching pattern
        all_fields.each do |field|
          fields_to_remove.add(field.name) if field.name =~ remove_pattern
        end
      else
        # No criteria specified, return original
        return @raw
      end

      # Build sets of refs to exclude
      field_refs_to_remove = Set.new
      widget_refs_to_remove = Set.new

      all_fields.each do |field|
        next unless fields_to_remove.include?(field.name)

        field_refs_to_remove.add(field.ref) if field.valid_ref?

        # Find all widget annotations for this field
        @resolver.each_object do |widget_ref, body|
          next unless body && DictScan.is_widget?(body)
          next if widget_ref == field.ref

          # Match by /Parent reference
          if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            widget_parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            if widget_parent_ref == field.ref
              widget_refs_to_remove.add(widget_ref)
              next
            end
          end

          # Also match by field name (/T)
          next unless body.include?("/T")

          t_tok = DictScan.value_token_after("/T", body)
          next unless t_tok

          widget_name = DictScan.decode_pdf_string(t_tok)
          if widget_name && widget_name == field.name
            widget_refs_to_remove.add(widget_ref)
          end
        end
      end

      # Collect objects to write (excluding removed fields and widgets)
      objects = []
      @resolver.each_object do |ref, body|
        next if field_refs_to_remove.include?(ref)
        next if widget_refs_to_remove.include?(ref)
        next unless body

        objects << { ref: ref, body: body }
      end

      # Process AcroForm to remove field references from /Fields array
      af_ref = acroform_ref
      if af_ref
        # Find the AcroForm object in our objects list
        af_obj = objects.find { |o| o[:ref] == af_ref }
        if af_obj
          af_body = af_obj[:body]
          fields_array_ref = DictScan.value_token_after("/Fields", af_body)

          if fields_array_ref && fields_array_ref =~ /\A(\d+)\s+(\d+)\s+R/
            # /Fields points to separate array object
            arr_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
            arr_obj = objects.find { |o| o[:ref] == arr_ref }
            if arr_obj
              arr_body = arr_obj[:body]
              field_refs_to_remove.each do |field_ref|
                arr_body = DictScan.remove_ref_from_array(arr_body, field_ref)
              end
              # Clean up empty array
              arr_body = arr_body.strip.gsub(/\[\s+\]/, "[]")
              arr_obj[:body] = arr_body
            end
          elsif af_body.include?("/Fields")
            # Inline /Fields array
            field_refs_to_remove.each do |field_ref|
              af_body = DictScan.remove_ref_from_inline_array(af_body, "/Fields", field_ref)
            end
            af_obj[:body] = af_body
          end
        end
      end

      # Process page objects to remove widget references from /Annots arrays
      # Also remove any orphaned widget references (widgets that reference non-existent fields)
      objects_in_file = Set.new(objects.map { |o| o[:ref] })
      field_refs_in_file = Set.new
      objects.each do |obj|
        body = obj[:body]
        # Check if this is a field object
        if body&.include?("/FT") && body.include?("/T")
          field_refs_in_file.add(obj[:ref])
        end

        body = obj[:body]
        next unless DictScan.is_page?(body)

        # Handle inline /Annots array
        if body =~ %r{/Annots\s*\[(.*?)\]}
          annots_array_str = ::Regexp.last_match(1)

          # Remove widgets that match removed fields
          widget_refs_to_remove.each do |widget_ref|
            annots_array_str = annots_array_str.gsub(/\b#{widget_ref[0]}\s+#{widget_ref[1]}\s+R\b/, "").strip
            annots_array_str = annots_array_str.gsub(/\s+/, " ")
          end

          # Also remove orphaned widget references (widgets not in objects_in_file or pointing to non-existent fields)
          annots_refs = annots_array_str.scan(/(\d+)\s+(\d+)\s+R/).map { |n, g| [Integer(n), Integer(g)] }
          annots_refs.each do |annot_ref|
            # Check if this annotation is a widget that should be removed
            if objects_in_file.include?(annot_ref)
              # Widget exists - check if it's an orphaned widget (references non-existent field)
              widget_obj = objects.find { |o| o[:ref] == annot_ref }
              if widget_obj && DictScan.is_widget?(widget_obj[:body])
                widget_body = widget_obj[:body]
                # Check if widget references a parent field that doesn't exist
                if widget_body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
                  parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
                  unless field_refs_in_file.include?(parent_ref)
                    # Parent field doesn't exist - orphaned widget, remove it
                    annots_array_str = annots_array_str.gsub(/\b#{annot_ref[0]}\s+#{annot_ref[1]}\s+R\b/, "").strip
                    annots_array_str = annots_array_str.gsub(/\s+/, " ")
                  end
                end
              end
            else
              # Widget object doesn't exist - remove it
              annots_array_str = annots_array_str.gsub(/\b#{annot_ref[0]}\s+#{annot_ref[1]}\s+R\b/, "").strip
              annots_array_str = annots_array_str.gsub(/\s+/, " ")
            end
          end

          new_annots = if annots_array_str.empty? || annots_array_str.strip.empty?
                         "[]"
                       else
                         "[#{annots_array_str}]"
                       end

          new_body = body.sub(%r{/Annots\s*\[.*?\]}, "/Annots #{new_annots}")
          obj[:body] = new_body
        # Handle indirect /Annots array reference
        elsif body =~ %r{/Annots\s+(\d+)\s+(\d+)\s+R}
          annots_array_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          annots_obj = objects.find { |o| o[:ref] == annots_array_ref }
          if annots_obj
            annots_body = annots_obj[:body]

            # Remove widgets that match removed fields
            widget_refs_to_remove.each do |widget_ref|
              annots_body = DictScan.remove_ref_from_array(annots_body, widget_ref)
            end

            # Also remove orphaned widget references
            annots_refs = annots_body.scan(/(\d+)\s+(\d+)\s+R/).map { |n, g| [Integer(n), Integer(g)] }
            annots_refs.each do |annot_ref|
              if objects_in_file.include?(annot_ref)
                widget_obj = objects.find { |o| o[:ref] == annot_ref }
                if widget_obj && DictScan.is_widget?(widget_obj[:body])
                  widget_body = widget_obj[:body]
                  if widget_body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
                    parent_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
                    unless field_refs_in_file.include?(parent_ref)
                      annots_body = DictScan.remove_ref_from_array(annots_body, annot_ref)
                    end
                  end
                end
              else
                annots_body = DictScan.remove_ref_from_array(annots_body, annot_ref)
              end
            end

            annots_obj[:body] = annots_body
          end
        end
      end

      # Sort objects by object number
      objects.sort_by! { |obj| obj[:ref][0] }

      # Write the cleaned PDF
      writer = PDFWriter.new
      writer.write_header

      objects.each do |obj|
        writer.write_object(obj[:ref], obj[:body])
      end

      writer.write_xref

      trailer_dict = @resolver.trailer_dict
      info_ref = nil
      if trailer_dict =~ %r{/Info\s+(\d+)\s+(\d+)\s+R}
        info_ref = [::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i]
      end

      # Write trailer
      max_obj_num = objects.map { |obj| obj[:ref][0] }.max || 0
      writer.write_trailer(max_obj_num + 1, root_ref, info_ref)

      writer.output
    end

    # Clean up in-place (mutates current instance)
    def clear!(...)
      cleaned_content = clear(...).freeze
      @raw = cleaned_content
      @resolver.clear_cache
      @resolver = AcroThat::ObjectResolver.new(cleaned_content)
      @patches = []

      self
    end

    # Write out with an incremental update
    def write(path_out = nil, flatten: true)
      deduped_patches = @patches.reverse.uniq { |p| p[:ref] }.reverse
      writer = AcroThat::IncrementalWriter.new(@raw, deduped_patches)
      @raw = writer.render.freeze
      @patches = []
      @resolver.clear_cache
      @resolver = AcroThat::ObjectResolver.new(@raw)

      flatten! if flatten

      if path_out
        File.binwrite(path_out, @raw)
        return true
      else
        return @raw
      end
    end

    private

    def collect_pages_from_tree(pages_ref, page_objects)
      pages_body = @resolver.object_body(pages_ref)
      return unless pages_body

      # Extract /Kids array from Pages object
      if pages_body =~ %r{/Kids\s*\[(.*?)\]}m
        kids_array = ::Regexp.last_match(1)
        # Extract all object references from Kids array in order
        kids_array.scan(/(\d+)\s+(\d+)\s+R/) do |num_str, gen_str|
          kid_ref = [num_str.to_i, gen_str.to_i]
          kid_body = @resolver.object_body(kid_ref)

          # Check if this kid is a page (not /Type/Pages)
          if kid_body && DictScan.is_page?(kid_body)
            page_objects << kid_ref unless page_objects.include?(kid_ref)
          elsif kid_body && kid_body.include?("/Type /Pages")
            # Recursively find pages in this Pages node
            collect_pages_from_tree(kid_ref, page_objects)
          end
        end
      end
    end

    # Find all page objects in document order
    # Returns an array of page references [obj_num, gen_num]
    def find_all_pages
      page_objects = []

      # First, try to get pages in document order via page tree
      root_ref = @resolver.root_ref
      if root_ref
        catalog_body = @resolver.object_body(root_ref)
        if catalog_body && catalog_body =~ %r{/Pages\s+(\d+)\s+(\d+)\s+R}
          pages_ref = [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
          collect_pages_from_tree(pages_ref, page_objects)
        end
      end

      # Fallback: collect all page objects if page tree didn't work
      if page_objects.empty?
        @resolver.each_object do |ref, body|
          next unless body

          next unless DictScan.is_page?(body)

          page_objects << ref unless page_objects.include?(ref)
        end

        # Sort by object number as fallback
        page_objects.sort_by! { |ref| ref[0] }
      end

      page_objects
    end

    # Find a page by its page number (1-indexed)
    # Returns [obj_num, gen_num] or nil if not found
    def find_page_by_number(page_num)
      page_objects = find_all_pages

      return nil if page_objects.empty?
      return page_objects[page_num - 1] if page_num.positive? && page_num <= page_objects.length

      page_objects[0] # Default to first page if page_num is out of range
    end

    def find_page_number_for_ref(page_ref)
      page_objects = find_all_pages

      return nil if page_objects.empty?

      page_index = page_objects.index(page_ref)
      return nil unless page_index

      page_index + 1
    end

    def next_fresh_object_number
      max_obj_num = 0
      @resolver.each_object do |ref, _|
        max_obj_num = [max_obj_num, ref[0]].max
      end
      @patches.each do |p|
        max_obj_num = [max_obj_num, p[:ref][0]].max
      end
      max_obj_num + 1
    end

    def acroform_ref
      root_ref = @resolver.root_ref
      return nil unless root_ref

      cat_body = @resolver.object_body(root_ref)

      return nil unless cat_body =~ %r{/AcroForm\s+(\d+)\s+(\d+)\s+R}

      [Integer(::Regexp.last_match(1)), Integer(::Regexp.last_match(2))]
    end
  end
end
