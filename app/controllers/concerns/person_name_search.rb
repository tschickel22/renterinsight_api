# Name matching for people-shaped records (leads, contacts, ...).
#
# Two bugs kept showing up in every hand-rolled `first_name ILIKE ? OR
# last_name ILIKE ?` search, so they're fixed once here:
#
#   1. Typing a full name found nothing. "don kill" is never a substring of
#      first_name alone or last_name alone, so Don Killins came back empty.
#      #person_name_where also matches the concatenated name, in both orders.
#
#   2. LIMIT without ORDER BY returned arbitrary rows. Global search takes 5
#      leads per type; against 3k leads Postgres handed back whichever 5 the
#      scan hit first, so searching "don" could miss Don entirely while
#      returning five people with "london" in an email. #person_name_order
#      ranks exact, then prefix, then contains, so the LIMIT keeps the best
#      matches instead of the first ones off the heap.
#
#   3. The query went into the LIKE pattern raw, so its wildcards were live.
#      A bare "%" matched every row in the table and "a_b@x.com" quietly
#      matched "axb@x.com". #person_name_like escapes them — always build the
#      :q value with it rather than interpolating "%#{query}%" by hand.
module PersonNameSearch
  extend ActiveSupport::Concern

  # The :q value for #person_name_where — a contains-pattern with the user's
  # own % and _ escaped so they match literally instead of acting as wildcards.
  def person_name_like(query)
    "%#{escape_like(query.to_s)}%"
  end

  # WHERE fragment binding the named param :q (build it with #person_name_like).
  # `extra` are additional columns to match on but NOT to rank by — phone,
  # company_name, title and friends, which are searchable but shouldn't
  # outrank someone's actual name.
  def person_name_where(table, extra: [])
    first = "COALESCE(#{table}.first_name, '')"
    last  = "COALESCE(#{table}.last_name, '')"

    clauses = [
      "#{table}.first_name ILIKE :q",
      "#{table}.last_name ILIKE :q",
      "(#{first} || ' ' || #{last}) ILIKE :q",
      "(#{last} || ' ' || #{first}) ILIKE :q"
    ]
    clauses += Array(extra).map { |c| "#{qualify(table, c)} ILIKE :q" }
    clauses.join(' OR ')
  end

  # ORDER BY fragment (already sanitized — wrap in Arel.sql at the call site).
  # Lower rank sorts first; id breaks ties so paging is stable.
  def person_name_order(table, query, email_column: 'email')
    first = "LOWER(COALESCE(#{table}.first_name, ''))"
    last  = "LOWER(COALESCE(#{table}.last_name, ''))"
    full  = "(#{first} || ' ' || #{last})"
    rankable = [first, last, full]
    rankable << "LOWER(COALESCE(#{qualify(table, email_column)}, ''))" if email_column

    exact  = rankable.map { |c| "#{c} = :exact" }.join(' OR ')
    prefix = rankable.map { |c| "#{c} LIKE :prefix" }.join(' OR ')

    sql = "CASE WHEN #{exact} THEN 0 WHEN #{prefix} THEN 1 ELSE 2 END, #{table}.id DESC"
    ActiveRecord::Base.sanitize_sql_array(
      [sql, { exact: query.to_s.downcase, prefix: "#{escape_like(query.to_s.downcase)}%" }]
    )
  end

  private

  def qualify(table, column)
    column.to_s.include?('.') ? column.to_s : "#{table}.#{column}"
  end

  # Backslash is Postgres' default LIKE escape character. Escape it first so a
  # query containing a literal backslash doesn't escape the character after it.
  def escape_like(value)
    value.gsub(/[\\%_]/) { |c| "\\#{c}" }
  end
end
