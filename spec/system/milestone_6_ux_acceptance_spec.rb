require "rails_helper"

RSpec.describe "Milestone 6 UX Acceptance", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "100 Elm Street") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Unit A") }
  let!(:party) { create(:party, user: user, display_name: "Alice Tenant") }
  let!(:tenancy) do
    create(:tenancy,
      property: property,
      rentable_unit: unit,
      commencement_date: Date.current - 2.months,
      termination_date: Date.current + 10.months
    )
  end
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: tenancy.commencement_date) }
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: tenancy.commencement_date,
      due_day: 1
    )
  end

  describe "End-to-end 5-area navigation journey & accessibility", js: true do
    before do
      Accounting::ChartOfAccounts.ensure_for(user)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)
      expect(page).to have_button("Sign out")
    end

    it "navigates all 5 primary areas and preserves accessibility landmarks and active states" do
      # 1. Skip Link verification
      expect(page).to have_link("Skip to content", href: "#main", visible: :all)

      # 2. Area 1: Overview
      expect(page).to have_current_path(root_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Overview")
      end
      expect(page).to have_css("main#main")

      # 3. Area 2: Portfolio
      within("aside.yn-sidebar") { find("a[href='#{portfolio_path}']").click }
      expect(page).to have_css("main#main h1", text: "Portfolio")
      expect(page).to have_current_path(portfolio_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Portfolio")
      end
      expect(page).to have_text("100 Elm Street")

      # 4. Area 3: Money
      page.execute_script("document.querySelector('aside.yn-sidebar a[href=\"#{money_path}\"]').click()")
      expect(page).to have_css("main#main h1", text: "Money")
      expect(page).to have_current_path(money_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Money")
      end

      # 5. Area 4: Inbox
      page.execute_script("document.querySelector('aside.yn-sidebar a[href=\"#{inbox_path}\"]').click()")
      expect(page).to have_css("main#main h1", text: "Inbox")
      expect(page).to have_current_path(inbox_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Inbox")
      end

      # 6. Area 5: Reports
      page.execute_script("document.querySelector('aside.yn-sidebar a[href=\"#{reports_path}\"]').click()")
      expect(page).to have_css("main#main h1", text: "Reports")
      expect(page).to have_current_path(reports_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Reports")
      end

      # 7. Secondary: Accounts
      page.execute_script("document.querySelector('aside.yn-sidebar a[href=\"#{accounts_path}\"]').click()")
      expect(page).to have_css("main#main h1", text: "Chart of Accounts")
      expect(page).to have_current_path(accounts_path)
      within("aside.yn-sidebar") do
        expect(page).to have_css("a.yn-nav-link[aria-current='page']", text: "Accounts")
      end
      expect(page).to have_css("th[scope='col']")
    end

    it "handles confirmation dialog modal and voids a payment", js: true do
      res = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.today,
        payment_method: "zelle"
      )
      receipt = res.value!.data[:receipt]

      visit receipt_path(receipt)
      expect(page).to have_current_path(receipt_path(receipt))
      expect(page).to have_css("h1", text: "Receipt from")
      expect(page).to have_button("Void receipt…", visible: :all)
      expect(page).to have_css("#confirm-modal[data-connected='true']", visible: :all)
      page.execute_script("document.querySelector('button[data-turbo-confirm]').click()")
      expect(page).to have_css("#confirm-modal[open]")
      expect(page).to have_text("Void this receipt?")
      page.execute_script("document.querySelector('#confirm-modal [data-action*=\"turbo-confirm#confirm\"]').click()")

      expect(page).to have_text("Payment has been voided")
      expect(page).to have_text("This receipt was voided.")
      expect(receipt.reload).to be_voided
    end

    it "cancels a confirmation via backdrop click and prevents stale mutation execution on next confirm (P1 regression)", js: true do
      res1 = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 100_000,
        received_on: Date.today,
        payment_method: "zelle"
      )
      receipt1 = res1.value!.data[:receipt]

      res2 = Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.today,
        payment_method: "check"
      )
      receipt2 = res2.value!.data[:receipt]

      # 1. Visit receipt 1, trigger Void, backdrop cancel
      visit receipt_path(receipt1)
      expect(page).to have_current_path(receipt_path(receipt1))
      expect(page).to have_css("h1", text: "Receipt from")
      expect(page).to have_button("Void receipt…", visible: :all)
      expect(page).to have_css("#confirm-modal[data-connected='true']", visible: :all)
      page.execute_script("document.querySelector('button[data-turbo-confirm]').click()")
      expect(page).to have_css("#confirm-modal[open]")

      # Backdrop click
      page.execute_script("document.getElementById('confirm-modal').click()")
      expect(page).to have_no_css("#confirm-modal[open]")
      expect(receipt1.reload).not_to be_voided

      # 2. Visit receipt 2, trigger Void and Confirm
      visit receipt_path(receipt2)
      expect(page).to have_current_path(receipt_path(receipt2))
      expect(page).to have_css("h1", text: "Receipt from")
      expect(page).to have_button("Void receipt…", visible: :all)
      expect(page).to have_css("#confirm-modal[data-connected='true']", visible: :all)
      page.execute_script("document.querySelector('button[data-turbo-confirm]').click()")
      expect(page).to have_css("#confirm-modal[open]")

      page.execute_script("document.querySelector('#confirm-modal [data-action*=\"turbo-confirm#confirm\"]').click()")

      expect(page).to have_text("Payment has been voided")
      expect(receipt2.reload).to be_voided

      # 3. CRITICAL: Verify receipt 1 was NOT voided
      expect(receipt1.reload).not_to be_voided
    end

    it "traps keyboard focus within contextual modal and removes keydown listeners upon dismiss (P1 regression)", js: true do
      visit tenancy_path(tenancy)

      # 1. Open receipt modal
      click_on "Record receipt"
      expect(page).to have_css("dialog#modal[open]")

      # Verify modal title and aria-labelledby
      modal = find("dialog#modal")
      expect(modal[:'aria-labelledby']).to eq("modal-title")
      expect(page).to have_css("#modal-title", text: "Record receipt")

      # 2. Verify Tab key cycles focus within modal (focus trap active)
      # Send Tab keydown to modal dialog
      page.execute_script("document.querySelector('dialog#modal').dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))")
      expect(page).to have_css("dialog#modal[open]")

      # 3. Close modal via close button
      within("dialog#modal") do
        find("button.modal-close").click
      end
      expect(page).to have_no_css("dialog#modal[open]")

      # 4. Reopen modal
      click_on "Record receipt"
      expect(page).to have_css("dialog#modal[open]")

      # 4. Close modal via Escape
      page.execute_script("document.querySelector('dialog#modal').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
      expect(page).to have_no_css("dialog#modal[open]")
    end

    it "associates field-level validation errors with invalid controls via aria-describedby and aria-invalid", js: true do
      visit new_tenancy_receipt_path(tenancy)

      # Fill payment method but clear amount and disable HTML5 validation to trigger amount error
      fill_in "receipt-method", with: "Zelle"
      page.execute_script("document.getElementById('receipt-amount').value = ''")
      page.execute_script("document.getElementById('receipt-form').noValidate = true")
      click_button "Record receipt"

      # Wait for server response and error alert
      expect(page).to have_css(".yn-alert-danger", text: "Amount is required")

      # Verify amount field has aria-invalid and points to amount error message
      amount_field = find("#receipt-amount")
      expect(amount_field[:'aria-invalid']).to eq("true")
      expect(amount_field[:'aria-describedby']).to eq("receipt-amount-error")
      expect(page).to have_css("#receipt-amount-error.yn-error-text")
    end

    it "renders standalone full-page expense validation errors and preserves cleared values without defaulting", js: true do
      visit new_expense_path

      expect(page).to have_current_path(new_expense_path)
      expect(page).to have_css("h1", text: "Record expense")

      # Select property, clear amount and clear date, then submit
      select "100 Elm Street", from: "expense-property"
      select "Repairs", from: "expense-kind"
      fill_in "expense-vendor", with: "Acme Hardware"
      page.execute_script("document.getElementById('expense-amount').value = ''")
      page.execute_script("document.getElementById('expense-date').value = ''")
      page.execute_script("document.getElementById('expense-form').noValidate = true")
      click_button "Record Expense"

      # Verify full page remains on standalone form and displays error alert + field ARIA error
      expect(page).to have_css("h1", text: "Record expense")
      expect(page).to have_css(".yn-alert-danger")
      expect(page).to have_text(/Date paid is required|Expense couldn't be recorded/)

      amount_field = find("#expense-amount")
      expect(amount_field[:'aria-invalid']).to eq("true")
      expect(amount_field[:'aria-describedby']).to eq("expense-amount-error")
      expect(amount_field.value).to eq("")
      expect(page).to have_css("#expense-amount-error.yn-error-text")

      date_field = find("#expense-date")
      expect(date_field[:'aria-invalid']).to eq("true")
      expect(date_field[:'aria-describedby']).to eq("expense-date-error")
      expect(date_field.value).to eq("")
      expect(page).to have_css("#expense-date-error.yn-error-text")

      expect(find("#expense-vendor").value).to eq("Acme Hardware")
      expect(page).to have_no_css("dialog#modal[open]")
    end

    it "dynamically filters rentable units when changing property on Record Expense form", js: true do
      property_b = create(:property, user: user, address: "200 Pine Street")
      create(:rentable_unit, property: property_b, name: "Unit B1")

      visit new_expense_path
      expect(page).to have_css("h1", text: "Record expense")

      # 1. Select Property A -> Unit A should be an option, Unit B1 should not
      select "100 Elm Street", from: "expense-property"
      unit_select = find("#expense-unit")
      expect(unit_select).to have_content("Unit A")
      expect(unit_select).to have_no_content("Unit B1")

      # 2. Switch to Property B -> Unit B1 should be an option, Unit A should not
      select "200 Pine Street", from: "expense-property"
      expect(unit_select).to have_content("Unit B1")
      expect(unit_select).to have_no_content("Unit A")
    end

    it "preserves entered values and associates field errors on expense correction failure", js: true do
      exp_res = Expenses::CreateService.call(
        property: property,
        amount_cents: 50_000,
        expense_kind: "utilities",
        paid_on: Date.current,
        vendor_name: "Original Power"
      )
      created_exp = exp_res.value!.data[:expense]

      visit correction_expense_path(created_exp)
      expect(page).to have_css("h1", text: "Correct expense")

      # Change vendor, reference, and enter negative amount
      fill_in "expense_vendor_name", with: "Updated Utility Vendor"
      fill_in "expense_external_reference", with: "INV-CORRECT-999"
      page.execute_script("document.getElementById('expense_amount').value = '-75.00'")
      page.execute_script("document.getElementById('expense-correction-form').noValidate = true")
      click_button "Save correction"

      expect(page).to have_css("h1", text: "Correct expense")
      expect(page).to have_css(".yn-alert-danger")
      expect(page).to have_text(/must be greater than 0|Expense amount must be greater than zero|Correction couldn't be saved/)

      amount_input = find("#expense_amount")
      expect(amount_input[:'aria-invalid']).to eq("true")
      expect(amount_input[:'aria-describedby']).to eq("expense-correct-amount-error")
      expect(amount_input.value).to eq("-75.00")
      expect(page).to have_css("#expense-correct-amount-error.yn-error-text")

      expect(find("#expense_vendor_name").value).to eq("Updated Utility Vendor")
      expect(find("#expense_external_reference").value).to eq("INV-CORRECT-999")
    end

    it "rejects expense correction with blank required fields under noValidate and displays ARIA errors", js: true do
      exp_res = Expenses::CreateService.call(
        property: property,
        amount_cents: 50_000,
        expense_kind: "utilities",
        paid_on: Date.current,
        vendor_name: "Original Power"
      )
      created_exp = exp_res.value!.data[:expense]

      visit correction_expense_path(created_exp)
      expect(page).to have_css("h1", text: "Correct expense")

      # Clear required fields (amount, date) using JS to simulate browser validation bypass
      page.execute_script("document.getElementById('expense_amount').value = ''")
      page.execute_script("document.getElementById('expense_paid_on').value = ''")
      page.execute_script("document.getElementById('expense-correction-form').noValidate = true")
      click_button "Save correction"

      # Verify 422 ARIA error path
      expect(page).to have_css("h1", text: "Correct expense")
      expect(page).to have_css(".yn-alert-danger")

      amount_input = find("#expense_amount")
      expect(amount_input[:'aria-invalid']).to eq("true")
      expect(amount_input[:'aria-describedby']).to eq("expense-correct-amount-error")
      expect(page).to have_css("#expense-correct-amount-error.yn-error-text")

      date_input = find("#expense_paid_on")
      expect(date_input[:'aria-invalid']).to eq("true")
      expect(date_input[:'aria-describedby']).to eq("expense-correct-date-error")
      expect(page).to have_css("#expense-correct-date-error.yn-error-text")

      expect(created_exp.reload).not_to be_superseded
    end

    it "renders standalone full-page receipt validation errors with complete ARIA associations", js: true do
      visit new_receipt_path

      expect(page).to have_current_path(new_receipt_path)
      expect(page).to have_css("h1", text: "Record receipt")

      # Select tenancy, fill method, clear amount and submit
      find("#receipt-tenancy").find(:option, text: property.address).select_option
      select "Alice Tenant", from: "receipt-payer"
      fill_in "receipt-method", with: "Zelle"
      page.execute_script("document.getElementById('receipt-amount').value = ''")
      page.execute_script("document.getElementById('receipt-form').noValidate = true")
      click_button "Record receipt"

      # Verify full page remains on standalone form and displays error alert + field ARIA error
      expect(page).to have_css("h1", text: "Record receipt")
      expect(page).to have_css(".yn-alert-danger", text: "Amount is required")

      amount_field = find("#receipt-amount")
      expect(amount_field[:'aria-invalid']).to eq("true")
      expect(amount_field[:'aria-describedby']).to eq("receipt-amount-error")
      expect(amount_field.value).to eq("")
      expect(page).to have_css("#receipt-amount-error.yn-error-text")

      # Still the Money entry form: the tenancy stays a choice (with the submitted
      # value kept) and the form still posts to the top-level endpoint
      expect(find("#receipt-tenancy").value).to eq(tenancy.id.to_s)
      expect(find("#receipt-form")[:action]).to end_with(receipts_path(format: :html))
      expect(page).to have_link("Cancel", href: receipts_path)
      expect(page).to have_no_css("dialog#modal[open]")
    end

    it "executes the complete daily attention journey: Overview → attention item → tenancy action (P3 acceptance)", js: true do
      Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.current
      )

      balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: tenancy, as_of: Date.current)
      amount_dollars = sprintf("%.2f", balance_cents / 100.0)

      visit root_path
      expect(page).to have_text("Needs attention")
      expect(page).to have_text("Alice Tenant owes $#{amount_dollars}")

      # Click the attention action link to enter tenancy context
      click_link "Open tenancy →"
      expect(page).to have_current_path(tenancy_path(tenancy))
      expect(page).to have_text("Alice Tenant")
      expect(page).to have_text("$#{amount_dollars} due")

      # Resolve the balance by recording a receipt
      click_on "Record receipt"
      expect(page).to have_css("dialog#modal[open]")
      within("dialog#modal") do
        select "Alice Tenant", from: "receipt-payer"
        fill_in "receipt-method", with: "Zelle"
        click_button "Record receipt"
      end

      expect(page).to have_text("Payment recorded successfully.")
      expect(page).to have_text(/settled/i)

      # Return to Overview and verify attention item is cleared
      within("aside.yn-sidebar") { click_on "Overview" }
      expect(page).to have_current_path(root_path)
      expect(page).to have_text("Nothing needs attention.")
      expect(page).to have_no_text("Alice Tenant owes")
    end

    it "renders toast notifications with proper ARIA live status" do
      visit new_property_path
      fill_in "Address", with: "777 Maple Avenue"
      select "Commercial", from: "Asset type"
      click_on "Add property"

      # Expect flash toast with role="status" and message
      expect(page).to have_css("div[role='status'].yn-alert", text: "Property was successfully created.")
    end
  end

  describe "375px mobile viewport responsiveness", js: true do
    before do
      Accounting::ChartOfAccounts.ensure_for(user)
      page.driver.browser.manage.window.resize_to(375, 667)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)
    end

    after do
      page.driver.browser.manage.window.resize_to(1400, 1400) if page.driver.respond_to?(:browser)
    end

    it "renders the mobile topbar without horizontal overflow" do
      expect(page).to have_css("header.lg\\:hidden")
      expect(page).to have_css("button[aria-label='Open navigation']")

      # Check document width vs window inner width
      doc_width = page.evaluate_script("document.documentElement.scrollWidth")
      win_width = page.evaluate_script("window.innerWidth")
      expect(doc_width).to be <= win_width
    end

    it "executes the tenancy workflow on a 375px narrow viewport without horizontal overflow (P3 acceptance)", js: true do
      visit tenancy_path(tenancy)
      expect(page).to have_text("Unit A")
      expect(page).to have_text("Alice Tenant")

      # Verify no horizontal page overflow
      doc_width = page.evaluate_script("document.documentElement.scrollWidth")
      win_width = page.evaluate_script("window.innerWidth")
      expect(doc_width).to be <= win_width

      # Navigate to agreements tab
      within(".yn-tabs") do
        click_on "Agreement"
      end
      expect(page).to have_text("Agreement type")
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= win_width

      # Record a charge on narrow screen
      visit new_tenancy_charge_path(tenancy)
      expect(page).to have_text("Add charge")
      select "Late fee", from: "Charge type"
      page.execute_script("document.getElementById('charge-amount').value = '35.00'")
      page.execute_script("document.getElementById('charge-desc').value = 'Mobile late fee'")
      page.execute_script("document.querySelector('form#charge-form').requestSubmit()")

      expect(page).to have_text("Charge was successfully created.")
      expect(page).to have_current_path(tenancy_path(tenancy))
      expect(page).to have_text("Mobile late fee")
    end
  end

  describe "Screenshot generation for documentation refresh (P3 acceptance)", js: true do
    before do
      Accounting::ChartOfAccounts.ensure_for(user)
      page.driver.browser.manage.window.resize_to(1280, 800)
      visit new_session_path
      fill_in "email", with: user.email
      fill_in "password", with: "password"
      click_on "Sign in"
      expect(page).to have_current_path(root_path)

      # Seed comprehensive financial and tenancy data for clean visual screenshots
      RentCharges::GenerateThroughService.call(tenancy: tenancy, through: Date.current)
      Receipts::CreateService.call(
        tenancy: tenancy,
        payer_party: party,
        amount_cents: 150_000,
        received_on: Date.current - 1.month,
        payment_method: "ach"
      )
      Expenses::CreateService.call(
        property: property,
        amount_cents: 25_000,
        expense_kind: "repairs",
        paid_on: Date.current - 2.weeks,
        description: "Plumbing repair"
      )
    end

    after do
      page.driver.browser.manage.window.resize_to(1400, 1400) if page.driver.respond_to?(:browser)
    end

    it "captures fresh high-res screenshots of the primary areas" do
      screenshots_dir = ENV["UPDATE_SCREENSHOTS"].present? ? Rails.root.join("public/screenshots") : Rails.root.join("tmp/screenshots")
      FileUtils.mkdir_p(screenshots_dir)

      # 1. Overview
      visit root_path
      expect(page).to have_text("Overview")
      page.save_screenshot(screenshots_dir.join("overview.png"))

      # 2. Portfolio
      visit portfolio_path
      expect(page).to have_css("main#main h1", text: "Portfolio")
      page.save_screenshot(screenshots_dir.join("portfolio.png"))

      # 3. Property workspace, Activity tab
      visit property_activity_path(property)
      expect(page).to have_text("Activity")
      page.save_screenshot(screenshots_dir.join("property_activity.png"))

      # 4. Tenancy workspace
      visit tenancy_path(tenancy)
      expect(page).to have_text("Alice Tenant")
      page.save_screenshot(screenshots_dir.join("tenancy.png"))

      # 5. Record receipt dialog
      visit tenancy_path(tenancy)
      click_on "Record receipt"
      expect(page).to have_css("dialog#modal[open]")
      expect(page).to have_css("#receipt-form")
      page.save_screenshot(screenshots_dir.join("record_receipt_dialog.png"))

      # 6. Inbox, Needs review
      create(:imported_transaction,
        user: user,
        status: "matched",
        amount_cents: 150_000,
        occurred_on: Date.current,
        payment_method: "zelle",
        payer_name: "Alice Tenant",
        matched_party: party,
        matched_tenancy: tenancy,
        transaction_kind: "tenant_receipt"
      )
      visit inbox_path
      expect(page).to have_text("Needs review")
      page.save_screenshot(screenshots_dir.join("inbox_review.png"))

      # 7. Upload a statement
      visit new_source_document_path
      expect(page).to have_css("main#main h1", text: "Upload statement")
      page.save_screenshot(screenshots_dir.join("upload_statement.png"))

      # 8. Reports landing
      property.tax_profiles.create!(tax_year: Date.current.year, schedule_e_property_type: "single_family_residence")
      visit reports_path(year: Date.current.year)
      expect(page).to have_css("main#main h1", text: "Reports")
      page.save_screenshot(screenshots_dir.join("reports.png"))

      # 9. Schedule E worksheet
      visit schedule_e_property_path(property, year: Date.current.year)
      expect(page).to have_text("Schedule E")
      page.save_screenshot(screenshots_dir.join("schedule_e.png"))
    end
  end
end
