require "rails_helper"

RSpec.describe "Application Shell Navigation", type: :system do
  let!(:user) { create(:user) }

  describe "desktop shell navigation" do
    before do
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_button("Sign out")
    end

    it "renders the 5 primary destinations, secondary accounting, and handles navigation" do
      # On Overview (root_path)
      within("aside.yn-sidebar") do
        expect(page).to have_link("Overview", href: root_path)
        expect(page).to have_link("Portfolio", href: portfolio_path)
        expect(page).to have_link("Money", href: money_path)
        expect(page).to have_link("Inbox", href: inbox_path)
        expect(page).to have_link("Reports", href: reports_path)
        expect(page).to have_link("Accounts", href: accounts_path)

        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Overview")
        expect(page).to have_text(user.email)
        expect(page).to have_button("Sign out")
      end

      # Navigate to Portfolio
      within("aside.yn-sidebar") { click_on "Portfolio" }
      expect(page).to have_current_path(portfolio_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Portfolio")
      end

      # Navigate to Money
      within("aside.yn-sidebar") { click_on "Money" }
      expect(page).to have_current_path(money_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Money")
      end

      # Navigate to Inbox
      within("aside.yn-sidebar") { click_on "Inbox" }
      expect(page).to have_current_path(inbox_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Inbox")
      end

      # Navigate to Reports
      within("aside.yn-sidebar") { click_on "Reports" }
      expect(page).to have_current_path(reports_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Reports")
      end

      # Navigate to Accounts (secondary Accounting section)
      within("aside.yn-sidebar") { click_on "Accounts" }
      expect(page).to have_current_path(accounts_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Accounts")
      end

      # Sign out
      within("aside.yn-sidebar") { click_on "Sign out" }
      expect(page).to have_current_path(new_session_path)
    end
  end

  describe "keyboard focus on Turbo Drive navigation", js: true do
    before do
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_button("Sign out")
    end

    it "moves focus to the heading of each page it navigates to, and leaves a full page load alone" do
      # A full load belongs to the skip link: nothing has been focused for the reader
      visit root_path
      expect(page).to have_css("h1")
      expect(page.evaluate_script("document.activeElement === document.body")).to be true

      # Each hop waits for the rendered heading before reading focus. Turbo
      # pushes the URL before it renders, so `have_current_path` alone can be
      # satisfied mid-visit, and `evaluate_script` never waits.
      # Sidebar link
      within("aside.yn-sidebar") { click_on "Portfolio" }
      expect(page).to have_css("main#main h1", text: "Portfolio")
      expect(page).to have_current_path(portfolio_path)
      expect(page.evaluate_script("document.activeElement.tagName")).to eq("H1")
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Portfolio")
      # Focusable on purpose, but not an extra stop on the way through the page
      expect(page.evaluate_script("document.activeElement.getAttribute('tabindex')")).to eq("-1")

      # Tab within a page
      within("nav[aria-label='Portfolio sections']") { click_on "Parties" }
      expect(page).to have_css(".yn-tab[aria-current='page']", text: "Parties")
      expect(page).to have_current_path(parties_path)
      expect(page.evaluate_script("document.activeElement.tagName")).to eq("H1")

      # And on to another destination
      within("aside.yn-sidebar") { click_on "Inbox" }
      expect(page).to have_css("main#main h1", text: "Inbox")
      expect(page).to have_current_path(inbox_path)
      expect(page.evaluate_script("document.activeElement.textContent.trim()")).to eq("Inbox")
    end
  end

  # A table wider than the screen scrolls sideways in its own container, and a
  # scroll container is not reachable with a keyboard unless something gives it
  # a tab stop (WCAG 2.1.1). The markup ships with one so the affordance holds
  # without JavaScript; `table_scroll_controller` takes it back off any table
  # that fits, so a reader is not stopped on a table that has nothing hidden.
  describe "keyboard access to horizontally scrolling tables", js: true do
    let!(:property) { create(:property, user: user, address: "100 Elm Street") }
    let!(:unit) { create(:rentable_unit, property: property, name: "Unit A With A Long Name") }
    let!(:party) { create(:party, user: user, display_name: "Alexander Montgomery-Smith") }
    let!(:tenancy) do
      create(:tenancy, :month_to_month, property: property, rentable_unit: unit,
        commencement_date: Date.current - 2.months)
    end
    let!(:tenancy_party) do
      create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: tenancy.commencement_date)
    end
    let!(:rent_term) do
      create(:rent_term, tenancy: tenancy, amount_cents: 245_000, effective_from: tenancy.commencement_date, due_day: 1)
    end

    before do
      Accounting::ChartOfAccounts.ensure_for(user)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)
    end

    after { resize_window_to(1400, 1400) }

    it "gives a scrolling table a labelled tab stop and scrolls it from the keyboard" do
      resize_window_to(375, 667)
      visit tenancy_agreement_path(tenancy)
      expect(page).to have_text("Participants")

      scroller = find(".yn-table-scroll[aria-labelledby='participants-heading']", match: :first)
      expect(scroller[:tabindex]).to eq("0")
      expect(scroller[:role]).to eq("region")
      expect(page).to have_css("#participants-heading", text: "Participants")

      # Reachable, and once focused the arrow keys move the hidden columns into
      # view. Without the tab stop there is no way to get to them at all.
      page.execute_script("document.querySelector(\".yn-table-scroll[aria-labelledby='participants-heading']\").focus()")
      expect(page.evaluate_script("document.activeElement.className")).to include("yn-table-scroll")

      expect(page.evaluate_script("document.activeElement.scrollLeft")).to eq(0)
      page.execute_script("document.activeElement.scrollLeft = 9999")
      expect(page.evaluate_script("document.activeElement.scrollLeft")).to be > 0
    end

    # No JavaScript on purpose: this is the half of the behavior the server
    # owns, and the controller would strip it on a viewport this wide.
    it "renders the tab stop and the name server side, so no-JS keeps the affordance", js: false do
      visit tenancy_agreement_path(tenancy)

      expect(page).to have_css(
        ".yn-table-scroll[tabindex='0'][role='region'][aria-labelledby='participants-heading']",
        visible: :all
      )
    end

    it "leaves no tab stop or landmark on a table that fits" do
      resize_window_to(1400, 1000)
      visit tenancy_agreement_path(tenancy)
      expect(page).to have_text("Participants")

      expect(page).to have_css(".yn-table-scroll")
      expect(page).to have_no_css(".yn-table-scroll[tabindex]")
      expect(page).to have_no_css(".yn-table-scroll[role='region']")
    end

    it "restores the table's accessible name and region role when restored from Turbo page cache on a narrow screen" do
      resize_window_to(1400, 1000)
      visit tenancy_agreement_path(tenancy)
      expect(page).to have_text("Participants")

      # Wide viewport: table fits, controller strips tabindex and landmark attributes
      expect(page).to have_no_css(".yn-table-scroll[tabindex]")
      expect(page).to have_no_css(".yn-table-scroll[role='region']")

      # Navigate away via Turbo Drive, which caches the current mutated page
      within(".yn-tabs") { click_on "Activity" }
      expect(page).to have_current_path(tenancy_path(tenancy))

      # Narrow viewport (table will now overflow upon return)
      resize_window_to(375, 667)

      # Restore Agreement page from Turbo cache via browser back
      page.go_back
      expect(page).to have_current_path(tenancy_agreement_path(tenancy))
      expect(page).to have_text("Participants")

      scroller = find(".yn-table-scroll[aria-labelledby='participants-heading']", match: :first)
      expect(scroller[:tabindex]).to eq("0")
      expect(scroller[:role]).to eq("region")
      expect(scroller["aria-labelledby"]).to eq("participants-heading")
    end

    it "removes the tab stop when focus leaves a table that stopped overflowing" do
      resize_window_to(375, 667)
      visit tenancy_agreement_path(tenancy)
      expect(page).to have_text("Participants")

      # Table overflows at 375px: focus the scroller
      scroller = find(".yn-table-scroll[aria-labelledby='participants-heading']", match: :first)
      expect(scroller[:tabindex]).to eq("0")
      page.execute_script("document.querySelector(\".yn-table-scroll[aria-labelledby='participants-heading']\").focus()")
      expect(page.evaluate_script("document.activeElement.className")).to include("yn-table-scroll")

      # Widen viewport: table now fits, but container is focused so it keeps tabindex until blur
      resize_window_to(1400, 1000)
      wait_for_animation_frame

      # Move focus away
      page.execute_script("document.activeElement.blur()")
      wait_for_animation_frame

      expect(page).to have_no_css(".yn-table-scroll[tabindex]")
      expect(page).to have_no_css(".yn-table-scroll[role='region']")
    end
  end

  describe "mobile navigation drawer", js: true do
    before do
      resize_window_to(375, 700)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)
    end

    after do
      resize_window_to(1400, 1400)
    end

    it "opens, closes via close button and Escape key, restores focus, and navigates destinations from mobile drawer" do
      page.execute_script("document.querySelector('header.lg\\\\:hidden button[aria-label=\"Open navigation\"]').click()")

      # Check if dialog opened with links
      expect(page).to have_css("#navigation-drawer[open]")
      within("#navigation-drawer") do
        expect(page).to have_link("Overview", href: root_path)
        expect(page).to have_link("Portfolio", href: portfolio_path)
        expect(page).to have_link("Money", href: money_path)
        expect(page).to have_link("Inbox", href: inbox_path)
        expect(page).to have_link("Reports", href: reports_path)
        expect(page).to have_link("Accounts", href: accounts_path)
      end

      # Close drawer via close button and assert focus returns
      page.execute_script("document.querySelector('#navigation-drawer button[aria-label=\"Close navigation\"]').click()")
      expect(page).to have_no_css("#navigation-drawer[open]")
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Open navigation")

      # Reopen the drawer and close it via Escape, then assert focus returns.
      # The keydown is dispatched from the page rather than typed: headless
      # Chrome on this machine intermittently drops synthesized input (see
      # spec/support/capybara_click_delivery.rb), and a real keystroke that is
      # swallowed reads as a drawer that ignored Escape. The window-level
      # handler is what returns focus, and that is what this exercises; the
      # dialog's native cancel path is not covered here.
      page.execute_script("document.querySelector('header.lg\\\\:hidden button[aria-label=\"Open navigation\"]').click()")
      expect(page).to have_css("#navigation-drawer[open]")
      page.execute_script("document.querySelector('#navigation-drawer').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
      expect(page).to have_no_css("#navigation-drawer[open]")
      expect(page.evaluate_script("document.activeElement.getAttribute('aria-label')")).to eq("Open navigation")

      # Reopen drawer and navigate to Portfolio
      page.execute_script("document.querySelector('header.lg\\\\:hidden button[aria-label=\"Open navigation\"]').click()")
      expect(page).to have_css("#navigation-drawer[open]")
      page.execute_script("document.querySelector('#navigation-drawer a[href=\"#{portfolio_path}\"]').click()")

      # Assert mobile navigation succeeded
      expect(page).to have_current_path(portfolio_path)
      expect(page).to have_text("Portfolio")
    end
  end
end
