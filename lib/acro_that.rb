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
require_relative "acro_that/page"
require_relative "acro_that/document"

# Load actions base first (needed by fields)
require_relative "acro_that/actions/base"

# Load fields
require_relative "acro_that/fields/base"
require_relative "acro_that/fields/radio"
require_relative "acro_that/fields/text"
require_relative "acro_that/fields/checkbox"
require_relative "acro_that/fields/signature"

# Load actions
require_relative "acro_that/actions/add_field"
require_relative "acro_that/actions/update_field"
require_relative "acro_that/actions/remove_field"

module AcroThat
end
