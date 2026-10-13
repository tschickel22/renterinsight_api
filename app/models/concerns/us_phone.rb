# frozen_string_literal: true

# The one way a customer's phone number is written: 303-586-4420.
#
# Used for leads, contacts and accounts. A US number typed any way, such as
# (303) 586-4420, 3035864420 or +1 303.586.4420, is stored like that. Anything
# that is not 10 digits (an international number, an extension) is kept as
# typed rather than mangled. Sending, inbound matching and duplicate checks
# all strip to digits first, so they read either form. Users' own numbers and
# Twilio numbers stay E.164 and do not use this.
module UsPhone
  FORMAT = /\A\d{3}-\d{3}-\d{4}\z/

  def self.format(value)
    return value if value.nil?

    text = value.to_s.strip
    digits = text.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    return text unless digits.length == 10

    "#{digits[0, 3]}-#{digits[3, 3]}-#{digits[6, 4]}"
  end

  # SQL for the backfill: the same rule as format, for a column.
  def self.backfill_sql(table, column)
    digits = "regexp_replace(#{column}, '[^0-9]', '', 'g')"
    ten = "right(#{digits}, 10)"
    <<~SQL.squish
      UPDATE #{table} SET #{column} = substr(#{ten}, 1, 3) || '-' || substr(#{ten}, 4, 3) || '-' || substr(#{ten}, 7, 4)
      WHERE #{column} IS NOT NULL AND #{column} !~ '^[0-9]{3}-[0-9]{3}-[0-9]{4}$'
        AND (#{digits} ~ '^[0-9]{10}$' OR #{digits} ~ '^1[0-9]{10}$')
    SQL
  end
end
