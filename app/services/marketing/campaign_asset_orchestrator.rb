# frozen_string_literal: true

module Marketing
  # Fans one brief out to every asset generator.
  #
  # This is the point of Campaign Desk: a marketer describes an offer once and
  # gets the email, the landing page and the follow-up as a single coherent
  # campaign. The coherence comes from every generator receiving the SAME
  # Marketing::Brief — not from anything this class does afterwards. Given
  # separate prompts, the landing page and the email that drives traffic to it
  # end up making different promises, which is worse than having no landing page.
  #
  # Assets are generated independently and failures are reported per asset. A
  # marketer who asked for three things and got two, clearly labelled, can work
  # with that; one who got an error page has nothing.
  class CampaignAssetOrchestrator
    Result = Struct.new(:assets, :failures, keyword_init: true) do
      def any?    = assets.any?
      def failed? = failures.any?
    end

    # Which assets to attempt. Landing page is opt-in because a tenant may not
    # have the module — Campaign Desk lists it as optional, so it must degrade
    # to "no landing page" rather than erroring.
    def initialize(brief:, include_landing_page: true)
      @brief = brief
      @include_landing_page = include_landing_page
    end

    def call
      assets = {}
      failures = {}

      if @include_landing_page
        begin
          assets[:landing_page] = LandingPages::AiBuilder
                                    .new(company: @brief.company, user: @brief.user)
                                    .generate(brief: @brief)
        rescue LandingPages::AiBuilder::CreditLimitError => e
          # Distinguished from a generation failure: the marketer can act on a
          # credit limit, and a retry will not help.
          failures[:landing_page] = { error: e.message, retryable: false }
        rescue StandardError => e
          Rails.logger.warn("[CampaignAssetOrchestrator] landing page: #{e.class}: #{e.message}")
          failures[:landing_page] = { error: e.message, retryable: true }
        end
      end

      Result.new(assets: assets, failures: failures)
    end
  end
end
