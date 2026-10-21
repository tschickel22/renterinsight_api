# frozen_string_literal: true

# A rep's contact card (vCard) behind a signed public link, so a text can say
# "save my number" and one tap puts the rep in the lead's phone.
#
# The link names the user by a signed id and never expires: a card saved from a
# text months ago should still open. It stops working when the user is no
# longer active, so a rep who leaves takes their card with them.
module ContactCard
  PURPOSE = :contact_card

  module_function

  def url_for(user)
    return nil if user.nil?

    "#{Messaging::TrackingUrl.base}/vc/#{Rails.application.message_verifier(PURPOSE).generate(user.id)}"
  end

  # The active user a token names, or nil.
  def user_for(token)
    id = Rails.application.message_verifier(PURPOSE).verified(token.to_s)
    id && User.find_by(id: id, status: 'active')
  end

  def filename(user)
    name = [user.first_name, user.last_name].compact.join('-').parameterize.presence || 'contact'
    "#{name}.vcf"
  end

  # vCard 3.0, which both iPhone and Android contacts open.
  def vcard(user)
    company = user.try(:company)
    first = user.first_name.to_s.strip
    last = user.last_name.to_s.strip
    full = [first, last].reject(&:blank?).join(' ').presence || user.email

    lines = ['BEGIN:VCARD', 'VERSION:3.0']
    lines << "N:#{escape(last)};#{escape(first)};;;"
    lines << "FN:#{escape(full)}"
    lines << "ORG:#{escape(company.name)}" if company&.name.present?
    lines << "TITLE:#{escape(user.title)}" if user.try(:title).present?
    lines << "TEL;TYPE=CELL,VOICE:#{escape(user.phone)}" if user.phone.present?
    lines << "TEL;TYPE=WORK,VOICE:#{escape(company.phone)}" if company&.phone.present? && company.phone != user.phone
    lines << "EMAIL;TYPE=INTERNET,WORK:#{escape(user.email)}" if user.email.present?
    lines << 'END:VCARD'
    "#{lines.join("\r\n")}\r\n"
  end

  # RFC 2426: backslash, comma, semicolon and newlines are escaped in values.
  def escape(value)
    value.to_s.gsub('\\', '\\\\\\\\').gsub(',', '\,').gsub(';', '\;').gsub(/\r?\n/, '\n')
  end
end
