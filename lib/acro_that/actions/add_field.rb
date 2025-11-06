# frozen_string_literal: true

module AcroThat
  module Actions
    # Action to add a new field to a PDF document
    # Delegates to field-specific classes for actual field creation
    class AddField
      include Base

      attr_reader :field_obj_num, :field_type, :field_value

      def initialize(document, name, options = {})
        @document = document
        @name = name
        @options = normalize_hash_keys(options)
        @metadata = normalize_hash_keys(@options[:metadata] || {})
      end

      def call
        type_input = @options[:type] || "/Tx"
        @options[:group_id]

        # Auto-set radio button flags if type is :radio and flags not explicitly set
        # MUST set this BEFORE creating the field handler so it gets passed correctly
        if [:radio, "radio"].include?(type_input) && !@metadata[:Ff]
          @metadata[:Ff] = 49_152
        end

        # Determine field type and create appropriate field handler
        field_handler = create_field_handler(type_input)

        # Call the field handler
        field_handler.call

        # Store field_obj_num from handler for compatibility
        @field_obj_num = field_handler.field_obj_num
        @field_type = field_handler.field_type
        @field_value = field_handler.field_value

        true
      end

      private

      def normalize_hash_keys(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) do |(key, value), normalized|
          sym_key = key.is_a?(Symbol) ? key : key.to_sym
          normalized[sym_key] = value.is_a?(Hash) ? normalize_hash_keys(value) : value
        end
      end

      def create_field_handler(type_input)
        is_radio = [:radio, "radio"].include?(type_input)
        group_id = @options[:group_id]

        if is_radio && group_id
          AcroThat::Fields::Radio.new(@document, @name, @options.merge(metadata: @metadata))
        elsif [:signature, "signature", "/Sig"].include?(type_input)
          AcroThat::Fields::Signature.new(@document, @name, @options.merge(metadata: @metadata))
        elsif [:checkbox, "checkbox"].include?(type_input)
          AcroThat::Fields::Checkbox.new(@document, @name, @options.merge(metadata: @metadata))
        else
          # Default to text field
          AcroThat::Fields::Text.new(@document, @name, @options.merge(metadata: @metadata))
        end
      end
    end
  end
end
