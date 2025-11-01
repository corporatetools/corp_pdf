# frozen_string_literal: true

require "strscan"
require "stringio"
require "zlib"
require "base64"
require "set"

require_relative "acro_that/dict_scan"
require_relative "acro_that/object_resolver"
require_relative "acro_that/objstm"
require_relative "acro_that/pdf_writer"
require_relative "acro_that/incremental_writer"
require_relative "acro_that/field"
require_relative "acro_that/document"

# Load actions
require_relative "acro_that/actions/base"
require_relative "acro_that/actions/add_field"
require_relative "acro_that/actions/update_field"
require_relative "acro_that/actions/remove_field"
require_relative "acro_that/actions/add_signature_appearance"

module AcroThat
end
