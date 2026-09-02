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

  describe "mobile navigation drawer", js: true do
    before do
      page.driver.browser.manage.window.resize_to(375, 700)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)
    end

    after do
      page.driver.browser.manage.window.resize_to(1400, 1400) if page.driver.respond_to?(:browser)
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

      # Reopen drawer and close via Escape key and assert focus returns
      page.execute_script("document.querySelector('header.lg\\\\:hidden button[aria-label=\"Open navigation\"]').click()")
      expect(page).to have_css("#navigation-drawer[open]")
      page.driver.browser.action.send_keys(:escape).perform
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
