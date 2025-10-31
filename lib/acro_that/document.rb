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
             end
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
      flattened_content = flatten
      @raw = flattened_content
      @resolver = AcroThat::ObjectResolver.new(flattened_content)
      @patches = []

      self
    end

    # Return an array of Field(name, value, type, ref)
    def list_fields
      fields = []
      field_widgets = {}
      widgets_by_name = {}

      # First pass: collect widget information
      @resolver.each_object do |_ref, body|
        next unless DictScan.is_widget?(body)

        # Extract position from widget
        rect_tok = DictScan.value_token_after("/Rect", body)
        next unless rect_tok && rect_tok.start_with?("[")

        # Parse [x y x+width y+height] format
        rect_values = rect_tok.scan(/[-+]?\d*\.?\d+/).map(&:to_f)
        next unless rect_values.length == 4

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

        # Second pass: collect all fields (both field objects and widget annotations with /T)
        next unless body&.include?("/T")

        is_widget_field = DictScan.is_widget?(body)
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

        position = {}
        is_widget_annot = DictScan.is_widget?(body)
        if is_widget_annot
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
      field = list_fields.find { |f| f.name == name }
      return false unless field

      field.update(new_value, new_name: new_name)
    end

    # Remove field by name from the AcroForm /Fields array
    def remove_field(fld)
      field = fld.is_a?(Field) ? fld : list_fields.find { |f| f.name == fld }
      return false unless field

      field.remove
    end

    # Write out with an incremental update
    def write(path_out = nil, flatten: false)
      deduped_patches = @patches.reverse.uniq { |p| p[:ref] }.reverse
      writer = AcroThat::IncrementalWriter.new(@raw, deduped_patches)
      @raw = writer.render
      @patches = []
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

    def find_page_number_for_ref(page_ref)
      page_objects = []
      @resolver.each_object do |ref, body|
        next unless body&.include?("/Type /Page")

        page_objects << ref
      end

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
