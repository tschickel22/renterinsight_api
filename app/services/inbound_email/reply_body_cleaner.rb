# frozen_string_literal: true

module InboundEmail
  # Splits a reply's body into the NEW text vs the quoted original thread, so a
  # reply-notification can show what the person actually wrote and tuck the
  # quoted history (which often carries security-rewritten links, e.g.
  # Proofpoint urldefense) out of the way.
  #
  # Best-effort and conservative: it only cuts at high-confidence quote markers,
  # and returns the whole body as `reply` when it can't find one — never hiding
  # content it isn't sure about.
  module ReplyBodyCleaner
    # First occurrence of any of these begins the quoted original.
    QUOTE_MARKERS = [
      /<blockquote/i,                                   # Gmail/Apple/most clients
      /<div[^>]*class=["'][^"']*gmail_quote/i,          # Gmail
      /-{2,}\s*Original Message\s*-{2,}/i,              # Outlook (older)
      /_{5,}/,                                           # Outlook horizontal divider
      /\bOn .{0,120}?\bwrote:/im,                        # "On <date>, <name> wrote:"
      /\bFrom:.{0,200}?\bSent:/im,                       # Outlook header block
      /\bFrom:.{0,200}?\bDate:.{0,200}?\bSubject:/im     # Gmail/Apple header block
    ].freeze

    Result = Struct.new(:reply, :quoted, keyword_init: true)

    # @param html [String] the reply body (HTML or text)
    # @return [Result] reply: new content, quoted: original thread (or nil)
    def self.split(html)
      s = html.to_s
      return Result.new(reply: s, quoted: nil) if s.strip.empty?

      idx = QUOTE_MARKERS.filter_map { |re| s =~ re }.min
      return Result.new(reply: s, quoted: nil) if idx.nil? || idx.zero?

      reply = s[0...idx].strip
      quoted = s[idx..].strip
      # If stripping left essentially nothing, keep the whole thing rather than
      # show an empty reply (defensive: a reply that IS only a quote).
      return Result.new(reply: s, quoted: nil) if reply.empty?

      Result.new(reply: reply, quoted: quoted)
    end
  end
end
