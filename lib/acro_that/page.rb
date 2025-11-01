# frozen_string_literal: true

module AcroThat
  # Represents a page in a PDF document
  class Page
    attr_reader :page, :width, :height, :ref, :metadata, :document

    def initialize(page, width, height, ref, metadata, document)
      @page = page # Page number (1-indexed)
      @width = width
      @height = height
      @ref = ref # [obj_num, gen_num]
      @metadata = metadata # Hash with :rotate, :media_box, :crop_box, etc.
      @document = document
    end

    # Add a field to this page
    # Options are the same as Document#add_field, but :page is automatically set
    def add_field(name, options = {})
      # Automatically set the page number to this page
      options_with_page = options.merge(page: @page)
      @document.add_field(name, options_with_page)
    end

    # Get the page number
    def page_number
      @page
    end

    # Get the page reference [obj_num, gen_num]
    def page_ref
      @ref
    end

    # Check if page has rotation
    def rotated?
      !@metadata[:rotate].nil? && @metadata[:rotate] != 0
    end

    # Get rotation angle (0, 90, 180, 270)
    def rotation
      @metadata[:rotate] || 0
    end

    # Get MediaBox dimensions
    def media_box
      @metadata[:media_box]
    end

    # Get CropBox dimensions
    def crop_box
      @metadata[:crop_box]
    end

    # Get ArtBox dimensions
    def art_box
      @metadata[:art_box]
    end

    # Get BleedBox dimensions
    def bleed_box
      @metadata[:bleed_box]
    end

    # Get TrimBox dimensions
    def trim_box
      @metadata[:trim_box]
    end

    # String representation for debugging
    def to_s
      dims = width && height ? " #{width}x#{height}" : ""
      rot = rotated? ? " (rotated #{rotation}°)" : ""
      "#<AcroThat::Page page=#{page}#{dims}#{rot} ref=#{ref.inspect}>"
    end

    alias inspect to_s

    # Convert to hash for backward compatibility
    def to_h
      {
        page: @page,
        width: @width,
        height: @height,
        ref: @ref,
        metadata: @metadata
      }
    end
  end
end
