# frozen_string_literal: true

module Outreach
  # DealerTide's first playbook and product facts (Tom, 2026-11-18), written
  # from its help articles, website and campaign copy. It makes no claims about
  # competitors because none of those sources do. Other companies start empty,
  # so Renter Insight is never described as DealerTide.
  module StarterContent
    # Rewritten 2026-11-20 after the first production wave: each problem says
    # how DealerTide fixes it and which video shows it, so messages lead with a
    # problem instead of a question. Playbook answers end in a demo ask.
    PRODUCT_FACTS = <<~TEXT.strip
      ABOUT
      DealerTide is software built only for manufactured home retailers. Website, CRM, inventory, quotes, deals, installs, service, warranty, accounting and commissions live in one system, so nothing gets typed twice.
      It works on a phone as well as a computer, with iOS and Android apps. Tom says it is the only system in manufactured housing with mobile apps, project management and AI lead follow up together.
      Support is based in the US. DealerTide moves a dealer's data over for them. Pricing is never quoted in writing; it is covered on the demo. Demos are 30 minutes by video call with Tom.

      PROBLEMS WE SOLVE (the problem, how DealerTide fixes it, the video that shows it)

      Website shoppers leave because they cannot see a price. Most retailer sites show photos and a call for price button, so a buyer who wants to price a home their way moves on. TrueBuild lets a buyer pick a floor plan, choose finishes and see a real price right on the dealer's website, priced from the factory price book with the dealer's own markup. TrueView draws the home with the finishes they picked. A saved design arrives as a lead with every option and price, so the salesperson starts the call knowing what the buyer wants. It works on a DealerTide website or inside the dealer's own website. Video: Let buyers design their home on your website.

      Keeping the homes on the website up to date is a chore. DealerTide pulls homes from manufacturer catalogs, including Champion's inventory feed, with specs, floor plans and photos, so new models show up on the dealer's site without anyone typing them in. Video: Your manufacturer's homes, on your site automatically.

      Leads go cold before anyone answers, most of all at night and on weekends. Quinn, DealerTide's AI assistant, texts a new lead within minutes, answers from the dealer's own homes and facts, books the visit on the salesperson's calendar and hands the conversation to the team. Quinn can also chat with visitors on the dealer's website. Video: DealerTide in 80 seconds.

      Installs are run from group texts, phone calls and a whiteboard. Project management tracks every install from site prep to move-in in phases and tasks: contractors, bids and quotes, job costs against the budget, and contractor invoices that turn into draft bills. The buyer sees progress and the photos the dealer chooses to share. Video: Every install, from site prep to move-in.

      Job site photos get lost in phone galleries and group chats. Crews and contractors add photos and files to the step they belong to, and the dealer decides which ones the buyer sees. Video: Photos from the job site, without the group text.

      Prices get copied by hand from price sheets into quotes and orders. Manufacturer price books are loaded into DealerTide, so the quote, the deal and the order use the same prices and options, with the dealer's markup applied the same way every time. Video: From price sheet to factory order in one place.

      Warranty claims slip through and the money never comes back. DealerTide tracks every warranty claim from filing to payment, so none are forgotten. Video: Warranty money most dealers leave on the table.

      The same buyer details get typed into every form. A deal carries the buyer, the home, options and prices into quotes, agreements and forms such as credit applications, sent out for e-signature.

      The books live somewhere else and never match the sales floor. DealerTide has full accounting built in: invoices, bills, bank feeds, reconciliation, Profit and Loss and Balance Sheet. Or it syncs both ways with QuickBooks Online. A dealer on QuickBooks Online can run a trial switch first: it reads QuickBooks without changing anything there, and QuickBooks stays their books until they choose to go live.

      Commissions are worked out on a spreadsheet. Commission plans work out what each salesperson earned from the deal itself.

      Marketing takes time nobody has. From one request DealerTide drafts the email, texts, landing page, social posts and follow up for a campaign, and nothing goes out until the dealer reviews it. Facebook ads and social posts are built and scheduled in the same place, and every lead is tracked back to where it came from.

      Running more than one lot. DealerTide handles several locations, and each person sees the locations they work.

      Owners want answers without digging through reports. DealerTide connects to Claude and ChatGPT, so an owner can ask about their leads, deals and books in plain words, and the AI only sees what that person is allowed to see.
    TEXT

    PLAYBOOK = [
      { 'objection' => 'How much does it cost?', 'action' => 'reply', 'share_hint' => '',
        'answer' => "It depends on how many locations you have and which parts of the system you'd use, so I don't want to throw out a number that doesn't fit. On a 30 minute demo I can see what you need and go over real pricing. Would [two open times] work?" },
      { 'objection' => 'We already have a system', 'action' => 'reply', 'share_hint' => 'DealerTide in 80 seconds',
        'answer' => "Most dealers I talk to do. DealerTide puts your website, inventory, deals, installs, service, warranty and accounting in one place, so nothing gets typed twice. Worth 30 minutes to see it next to what you use now? I have [two open times]." },
      { 'objection' => 'Not a good time', 'action' => 'reply', 'share_hint' => '',
        'answer' => "Understood. Should I check back after the first of the month, or is there a better week?" },
      { 'objection' => 'We are too small', 'action' => 'reply', 'share_hint' => '',
        'answer' => "Smaller teams often feel double entry the most, since the same few people sell, order and run installs. DealerTide comes in pieces, so we'd only look at what fits your lot. Could you do [two open times] for a 30 minute look?" },
      { 'objection' => 'We use Trove', 'action' => 'reply', 'share_hint' => 'Let buyers design their home on your website',
        'answer' => "Good to know. In 30 minutes I can show you buyers pricing homes on your website with TrueBuild, then how that deal carries through inventory, installs and accounting, and you can compare for yourself. Would [two open times] work?" },
      { 'objection' => 'We use MH Manager', 'action' => 'reply', 'share_hint' => 'Let buyers design their home on your website',
        'answer' => "Good to know. In 30 minutes I can show you a buyer designing and pricing a home on your website, then how that deal carries through inventory, installs and accounting, and you can compare for yourself. Would [two open times] work?" },
      { 'objection' => 'We built our own', 'action' => 'reply', 'share_hint' => '',
        'answer' => "That says a lot about how you like to run things. A 30 minute look would tell you quickly what DealerTide covers that yours doesn't, and what it doesn't. Would [two open times] work?" },
      { 'objection' => 'Switching sounds like too much work', 'action' => 'reply', 'share_hint' => '',
        'answer' => "That's the right thing to worry about. We move your data over for you. If you're on QuickBooks Online, you can even run a trial switch first: it reads your QuickBooks without changing anything, and QuickBooks stays your books until you decide to go live. I can show you how it works in 30 minutes, [two open times]." },
      { 'objection' => 'Just send me some information', 'action' => 'reply', 'share_hint' => 'DealerTide in 80 seconds',
        'answer' => "Happy to. Here's the short overview. If it looks useful, I can walk you through just the parts that fit your lot in 30 minutes, [two open times]." },
      { 'objection' => 'Who are you, and how did you get my number?', 'action' => 'reply', 'share_hint' => '',
        'answer' => "This is Tom Schickel with DealerTide. Your details came from [where their details came from]. We make software for manufactured home retailers. If you'd rather not hear from me, just say so and I'll take you off the list." },
      { 'objection' => 'Is this really Tom? Are you a bot?', 'action' => 'handoff', 'share_hint' => '',
        'answer' => "Fair question. I'm an AI assistant working with Tom Schickel. Tom runs every demo himself. Would you like him to reach out to you directly?" },
      { 'objection' => 'Stop, remove me, or not interested', 'action' => 'opt_out', 'share_hint' => '',
        'answer' => "Understood. I've taken you off the list and you won't hear from me again." }
    ].freeze

    module_function

    def available_for?(company)
      company.name.to_s.match?(/\ADealerTide\b/i)
    end
  end
end
