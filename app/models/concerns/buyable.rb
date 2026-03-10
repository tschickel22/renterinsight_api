# frozen_string_literal: true

# Adds buyer support to Deal, Quote, and Invoice models.
# ALL buyers (including primary) are stored in entity_buyers.
# The deal's contact_id is the "deal contact" but buyer roles
# are managed entirely through entity_buyers.
#
# Include in models that support buyers:
#   class Deal < ApplicationRecord
#     include Buyable
#   end
#
module Buyable
  extend ActiveSupport::Concern

  included do
    has_many :entity_buyers, as: :buyable, dependent: :destroy
    has_many :buyer_contacts, through: :entity_buyers, source: :contact
  end

  # All active buyers, ordered by position
  def buyers
    entity_buyers.active.ordered.includes(:contact)
  end

  # All buyers as structured array for agreement rendering
  def all_buyers
    buyers.map do |eb|
      {
        contact: eb.contact,
        role: eb.role,
        role_label: eb.role_label,
        position: eb.position
      }
    end
  end

  # Copy buyers from another buyable record (e.g., deal → quote)
  def copy_buyers_from(source)
    return unless source.respond_to?(:entity_buyers)

    source.entity_buyers.active.ordered.each do |eb|
      entity_buyers.build(
        company_id: company_id,
        contact_id: eb.contact_id,
        role: eb.role,
        position: eb.position,
        notes: eb.notes
      )
    end
  end

  # JSON representation of all buyers for API responses
  def buyers_as_json
    all_buyers.map do |b|
      contact = b[:contact]
      {
        contact_id: contact.id,
        name: "#{contact.first_name} #{contact.last_name}".strip,
        email: contact.email,
        phone: contact.phone,
        role: b[:role],
        role_label: b[:role_label]
      }
    end
  end
end
