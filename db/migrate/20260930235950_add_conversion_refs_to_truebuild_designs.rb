# frozen_string_literal: true

# A design follows its buyer through lead conversion: the contact, account
# and deal it becomes part of, and the quote made from it.
class AddConversionRefsToTruebuildDesigns < ActiveRecord::Migration[8.0]
  def change
    add_reference :truebuild_designs, :contact, foreign_key: true
    add_reference :truebuild_designs, :account, foreign_key: true
    add_reference :truebuild_designs, :deal, foreign_key: true
    add_reference :truebuild_designs, :quote, foreign_key: true
  end
end
