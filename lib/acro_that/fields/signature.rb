# frozen_string_literal: true

require "chunky_png"

module AcroThat
  module Fields
    # Handles signature field creation
    class Signature
      include Base

      attr_reader :field_obj_num

      # Class method to add appearance to an existing signature field
      # Can be called from both Signature field creation and UpdateField
      def self.add_appearance(document, field_ref, image_data, width: nil, height: nil)
        new(document, "", {}).add_appearance_to_field(field_ref, image_data, width: width, height: height)
      end

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

        # If this is a signature field with image data, add the signature appearance
        if @field_value && !@field_value.empty?
          image_data = @field_value
          if image_data.is_a?(String) && (image_data.start_with?("data:image/") || (image_data.length > 50 && image_data.match?(%r{^[A-Za-z0-9+/]*={0,2}$})))
            field_ref = [@field_obj_num, 0]
            add_appearance_to_field(field_ref, image_data, width: width, height: height)
          end
        end

        true
      end

      def add_appearance_to_field(field_ref, image_data, width: nil, height: nil)
        return false unless field_ref && image_data && !image_data.empty?

        # Decode image data if needed
        decoded_image_data = image_data.is_a?(String) && image_data.start_with?("data:") ? decode_base64_data_uri(image_data) : decode_base64_if_needed(image_data)
        return false unless decoded_image_data && !decoded_image_data.empty?

        # Detect image format and dimensions
        image_info = detect_image_format(decoded_image_data)
        return false unless image_info

        # Find widget annotation for this field
        widget_ref = find_signature_widget(field_ref)
        return false unless widget_ref

        widget_body = get_object_body_with_patch(widget_ref)
        return false unless widget_body

        # Get widget rectangle for appearance size
        rect = extract_rect(widget_body)
        return false unless rect

        # Ensure width and height are positive
        rect_width = (rect[:x2] - rect[:x1]).abs
        rect_height = (rect[:y2] - rect[:y1]).abs
        return false if rect_width <= 0 || rect_height <= 0

        # Get field dimensions (use provided width/height or field rect)
        field_width = width || rect_width
        field_height = height || rect_height

        # Get image natural dimensions
        image_width = image_info[:width].to_f
        image_height = image_info[:height].to_f
        return false if image_width <= 0 || image_height <= 0

        # Calculate scaling factor to fit image within field while maintaining aspect ratio
        scale_x = field_width / image_width
        scale_y = field_height / image_height
        scale_factor = [scale_x, scale_y].min

        # Calculate scaled dimensions (maintains aspect ratio, fits within field)
        scaled_width = image_width * scale_factor
        scaled_height = image_height * scale_factor

        # Create Image XObject(s) - use natural image dimensions (not scaled)
        image_obj_num = next_fresh_object_number
        image_result = create_image_xobject(image_obj_num, decoded_image_data, image_info, image_width, image_height)
        image_body = image_result[:body]
        mask_obj_num = image_result[:mask_obj_num]

        # Create Form XObject (appearance stream) - use field dimensions for bounding box
        form_obj_num = mask_obj_num ? mask_obj_num + 1 : image_obj_num + 1
        form_body = create_form_xobject(form_obj_num, image_obj_num, field_width, field_height, scale_factor,
                                        scaled_width, scaled_height)

        # Queue new objects
        document.instance_variable_get(:@patches) << { ref: [image_obj_num, 0], body: image_body }
        if mask_obj_num
          document.instance_variable_get(:@patches) << { ref: [mask_obj_num, 0],
                                                         body: image_result[:mask_body] }
        end
        document.instance_variable_get(:@patches) << { ref: [form_obj_num, 0], body: form_body }

        # Update widget annotation with /AP dictionary
        # Use already-loaded widget_body as original (we already have it from line 62)
        # Only reload if we don't have it (shouldn't happen, but for safety)
        original_widget_body = widget_body || resolver.object_body(widget_ref)
        updated_widget = add_appearance_to_widget(widget_body, form_obj_num)
        apply_patch(widget_ref, updated_widget, original_widget_body)

        true
      end

      private

      def decode_base64_data_uri(data_uri)
        if data_uri =~ %r{^data:image/[^;]+;base64,(.+)$}
          Base64.decode64(Regexp.last_match(1))
        end
      end

      def decode_base64_if_needed(data)
        if data.is_a?(String) && data.match?(%r{^[A-Za-z0-9+/]*={0,2}$})
          begin
            Base64.decode64(data)
          rescue StandardError
            data.b
          end
        else
          data.is_a?(String) ? data.b : data
        end
      end

      def detect_image_format(data)
        # JPEG: starts with FF D8 FF
        if data.bytesize >= 3 && data.getbyte(0) == 0xFF && data.getbyte(1) == 0xD8 && data.getbyte(2) == 0xFF
          width, height = extract_jpeg_dimensions(data)
          return { format: :jpeg, width: width, height: height, filter: "/DCTDecode" } if width && height
        end

        # PNG: starts with 89 50 4E 47 0D 0A 1A 0A
        if data.bytesize >= 8 && data[0, 8] == "\x89PNG\r\n\x1A\n".b
          width, height = extract_png_dimensions(data)
          return { format: :png, width: width, height: height, filter: "/FlateDecode" } if width && height
        end

        nil
      end

      def extract_jpeg_dimensions(data)
        i = 2
        while i < data.bytesize - 9
          if data.getbyte(i) == 0xFF && (data.getbyte(i + 1) & 0xF0) == 0xC0 && (i + 8 < data.bytesize)
            height = (data.getbyte(i + 5) << 8) | data.getbyte(i + 6)
            width = (data.getbyte(i + 7) << 8) | data.getbyte(i + 8)
            return [width, height] if width.positive? && height.positive?
          end
          i += 1
        end
        [1, 1]
      end

      def extract_png_dimensions(data)
        if data.bytesize >= 24
          width = data[16, 4].unpack1("N")
          height = data[20, 4].unpack1("N")
          return [width, height]
        end
        nil
      end

      def find_signature_widget(field_ref)
        # First check patches (for newly created widgets)
        document.instance_variable_get(:@patches).each do |patch|
          next unless patch[:body]
          next unless DictScan.is_widget?(patch[:body])

          if patch[:body] =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            parent_ref = [Integer(Regexp.last_match(1)), Integer(Regexp.last_match(2))]
            return patch[:ref] if parent_ref == field_ref
          end

          if patch[:body].include?("/FT") && DictScan.value_token_after("/FT",
                                                                        patch[:body]) == "/Sig" && (patch[:ref] == field_ref)
            return patch[:ref]
          end
        end

        # Then check resolver (for existing widgets)
        resolver.each_object do |ref, body|
          next unless body && DictScan.is_widget?(body)

          if body =~ %r{/Parent\s+(\d+)\s+(\d+)\s+R}
            parent_ref = [Integer(Regexp.last_match(1)), Integer(Regexp.last_match(2))]
            return ref if parent_ref == field_ref
          end

          if body.include?("/FT") && DictScan.value_token_after("/FT", body) == "/Sig" && (ref == field_ref)
            return ref
          end
        end

        # Fallback: if field_ref itself is a widget
        body = get_object_body_with_patch(field_ref)
        return field_ref if body && DictScan.is_widget?(body) && body.include?("/FT") && DictScan.value_token_after(
          "/FT", body
        ) == "/Sig"

        nil
      end

      def extract_rect(widget_body)
        rect_tok = DictScan.value_token_after("/Rect", widget_body)
        return nil unless rect_tok && rect_tok.start_with?("[")

        values = rect_tok.scan(/[-+]?\d*\.?\d+/).map(&:to_f)
        return nil unless values.length == 4

        { x1: values[0], y1: values[1], x2: values[2], y2: values[3] }
      end

      def create_image_xobject(obj_num, image_data, image_info, _width, _height)
        stream_data = nil
        filter = image_info[:filter]
        mask_obj_num = nil
        mask_body = nil

        case image_info[:format]
        when :jpeg
          stream_data = image_data.b
        when :png
          begin
            png = ChunkyPNG::Image.from_io(StringIO.new(image_data))

            has_transparency = if png.palette
                                 png.palette.include?(ChunkyPNG::Color::TRANSPARENT)
                               else
                                 sample_size = [png.width * png.height, 1000].min
                                 step = [png.width * png.height / sample_size, 1].max
                                 has_alpha = false
                                 (0...(png.width * png.height)).step(step) do |i|
                                   x = i % png.width
                                   y = i / png.width
                                   alpha = ChunkyPNG::Color.a(png[x, y])
                                   if alpha < 255
                                     has_alpha = true
                                     break
                                   end
                                 end
                                 has_alpha
                               end

            width = png.width
            height = png.height

            rgb_data = +""
            alpha_data = +"" if has_transparency

            height.times do |y|
              width.times do |x|
                color = png[x, y]
                r = ChunkyPNG::Color.r(color)
                g = ChunkyPNG::Color.g(color)
                b = ChunkyPNG::Color.b(color)
                rgb_data << [r, g, b].pack("C*")

                if has_transparency
                  alpha = ChunkyPNG::Color.a(color)
                  alpha_data << [alpha].pack("C*")
                end
              end
            end

            stream_data = Zlib::Deflate.deflate(rgb_data)
            filter = "/FlateDecode"

            if has_transparency && alpha_data
              mask_obj_num = obj_num + 1
              compressed_alpha = Zlib::Deflate.deflate(alpha_data)
              mask_length = compressed_alpha.bytesize

              mask_body = "<<\n"
              mask_body += "  /Type /XObject\n"
              mask_body += "  /Subtype /Image\n"
              mask_body += "  /Width #{width}\n"
              mask_body += "  /Height #{height}\n"
              mask_body += "  /BitsPerComponent 8\n"
              mask_body += "  /ColorSpace /DeviceGray\n"
              mask_body += "  /Filter /FlateDecode\n"
              mask_body += "  /Length #{mask_length}\n"
              mask_body += ">>\n"
              mask_body += "stream\n"
              mask_body += compressed_alpha
              mask_body += "\nendstream"
            end
          rescue StandardError
            stream_data = image_data.b
          end
        else
          stream_data = image_data.b
        end

        stream_length = stream_data.bytesize

        dict = "<<\n"
        dict += "  /Type /XObject\n"
        dict += "  /Subtype /Image\n"
        dict += "  /Width #{image_info[:width]}\n"
        dict += "  /Height #{image_info[:height]}\n"
        dict += "  /BitsPerComponent 8\n"
        dict += "  /ColorSpace /DeviceRGB\n"
        dict += "  /Filter #{filter}\n"
        dict += "  /Length #{stream_length}\n"
        dict += "  /SMask #{mask_obj_num} 0 R\n" if mask_obj_num
        dict += ">>\n"
        dict += "stream\n"
        dict += stream_data
        dict += "\nendstream"

        { body: dict, mask_obj_num: mask_obj_num, mask_body: mask_body }
      end

      def create_form_xobject(_obj_num, image_obj_num, field_width, field_height, _scale_factor, scaled_width,
                              scaled_height)
        offset_x = 0.0
        offset_y = (field_height - scaled_height) / 2.0

        content_stream = "q\n"
        content_stream += "1 0 0 1 #{offset_x} #{offset_y} cm\n" if offset_x != 0 || offset_y != 0
        content_stream += "#{scaled_width} 0 0 #{scaled_height} 0 0 cm\n"
        content_stream += "/Im1 Do\n"
        content_stream += "Q"

        dict = "<<\n"
        dict += "  /Type /XObject\n"
        dict += "  /Subtype /Form\n"
        dict += "  /BBox [0 0 #{field_width} #{field_height}]\n"
        dict += "  /Resources << /XObject << /Im1 #{image_obj_num} 0 R >> >>\n"
        dict += "  /Length #{content_stream.bytesize}\n"
        dict += ">>\n"
        dict += "stream\n"
        dict += content_stream
        dict += "\nendstream"

        dict
      end

      def add_appearance_to_widget(widget_body, form_obj_num)
        new_ap_value = "<< /N #{form_obj_num} 0 R >>"

        if widget_body.include?("/AP")
          ap_key_match = widget_body.match(%r{/AP(?=[\s(<\[/])})
          return widget_body unless ap_key_match

          value_start = ap_key_match.end(0)
          value_start += 1 while value_start < widget_body.length && widget_body[value_start] =~ /\s/

          depth = 0
          value_end = value_start
          while value_end < widget_body.length
            if widget_body[value_end, 2] == "<<"
              depth += 1
              value_end += 2
            elsif widget_body[value_end, 2] == ">>"
              depth -= 1
              value_end += 2
              break if depth.zero?
            else
              value_end += 1
            end
          end

          before = widget_body[0...value_start]
          after = widget_body[value_end..]
          return "#{before}#{new_ap_value}#{after}"
        end

        if widget_body.include?(">>")
          widget_body.sub(/(\s*)>>\s*$/, "\\1/AP #{new_ap_value}\n\\1>>")
        else
          widget_body + " /AP #{new_ap_value}"
        end
      end
    end
  end
end
