# frozen_string_literal: true

module Plays
  # Something the dealer can fix: a missing answer, a rep from another company,
  # a play that is already on. The message is shown to them as written.
  class InstallError < StandardError; end
end
