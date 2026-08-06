class WebsitePage < ApplicationRecord
  # Associations
  belongs_to :website
  belongs_to :parent_page, class_name: 'WebsitePage', optional: true
  has_many :child_pages, class_name: 'WebsitePage', foreign_key: :parent_page_id

  # Only set for pages generated through Campaign Desk. A landing page built
  # from the standalone surface has no campaign, so this stays nil.
  belongs_to :campaign, optional: true

  # Which Content Profile this page was projected from, and which layout was
  # used. Kept so the page can be re-projected into a different design later
  # without re-uploading the source document. Survives cloning.
  belongs_to :site_content_profile, optional: true

  # The form that collects this page's leads. Denormalised out of the contact
  # block's content so a clone can decide whether to duplicate or share it, and
  # so a page can report its own submissions without scanning JSONB.
  belongs_to :intake_form, optional: true

  # 'page'    — an ordinary page in a dealer's site.
  # 'landing' — a campaign or offer landing page. Single purpose, kept out of
  #             site nav, and defaulted to noindex (see ensure_landing_defaults).
  PAGE_KINDS = %w[page landing].freeze

  # Validations
  validates :title, presence: true
  validates :path, presence: true, uniqueness: { scope: :website_id }
  validates :page_kind, inclusion: { in: PAGE_KINDS }

  # Callbacks
  before_validation :generate_path, if: -> { path.blank? }
  before_validation :apply_landing_defaults, on: :create

  # Scopes
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :visible, -> { where(is_visible: true) }
  scope :visible_in_nav, -> { where(show_in_nav: true) }
  scope :visible_in_footer, -> { where(show_in_footer: true) }
  scope :top_level, -> { where(parent_page_id: nil) }
  scope :ordinary, -> { where(page_kind: 'page') }
  scope :landing_pages, -> { where(page_kind: 'landing') }
  scope :published, -> { where.not(published_at: nil).where(is_visible: true) }

  # Returns the page path (used by as_json methods: [:full_path])
  def full_path
    path
  end

  def landing_page?
    page_kind == 'landing'
  end

  # Visibility
  def show!
    update!(is_visible: true)
  end

  def hide!
    update!(is_visible: false)
  end

  # Publishing a landing page is page-level.
  #
  # The marketing container it lives on is always site-published — Websites::HostResolver
  # only resolves published sites, and nobody would think to publish a container they
  # never see. So page state is the only thing gating whether a visitor can reach this.
  def publish!
    update!(is_visible: true, published_at: Time.current)
  end

  def unpublish!
    update!(is_visible: false, published_at: nil)
  end

  def published?
    published_at.present? && is_visible?
  end

  private

  def generate_path
    return if title.blank?
    self.path = "/#{title.parameterize}"
  end

  # Landing pages default to noindex.
  #
  # Clone-to-locations fans one offer across N rooftops with identical copy, which
  # is textbook duplicate content — a dozen near-identical pages competing with the
  # dealer's actual site. Campaign traffic arrives from an email, SMS, or ad, so
  # there is nothing to gain from indexing and a real ranking risk in allowing it.
  #
  # Set on create only. An author who deliberately switches a page to index keeps
  # that choice, and differentiating the copy is the point at which that becomes
  # a reasonable thing to do.
  def apply_landing_defaults
    return unless landing_page?

    self.robots = 'noindex, nofollow' if robots.blank?
    # A landing page is not part of site navigation. Defaulting these true (the
    # column default, correct for ordinary pages) would drop every campaign page
    # into the dealer's header and footer.
    self.show_in_nav = false if show_in_nav.nil? || show_in_nav?
    self.show_in_footer = false if show_in_footer.nil? || show_in_footer?
  end
end
